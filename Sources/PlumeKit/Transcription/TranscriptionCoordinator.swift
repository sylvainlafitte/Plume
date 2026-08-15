import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
///
/// mic.caf → "me", system.caf → diarized speakers; each track's segments are
/// shifted by its start offset, merged onto a common clock, echo-filtered, and
/// written into `meeting.md` with the summary left `*pending*`.
///
/// `.plume/state.json` is the queue: `resumePending()` rescans at launch, so a
/// crash mid-transcription just retries. Failures are recorded as a blocker on
/// the session and appended to `.plume/transcribe.log`; they never block later
/// jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    private var diarizer: Diarizing?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions with work left to do.
    ///
    /// Driven by `.plume/state.json` rather than the presence of an output file:
    /// summarization is a second failable step after the audio is gone, so
    /// "which stage did we reach" is the only sound question. Folder names sort
    /// chronologically, so oldest-first is a name sort.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let pending = entries
            .filter { dir in
                guard let state = SessionState.load(from: dir) else { return false }
                // Only transcription is automatic. A session awaiting its
                // summary is resting, not stuck — Phase 4/5 drive that on a
                // human trigger.
                return state.stage == .recorded && state.isReadyForWork
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                try await transcribe(dir)
                try? SessionState.advance(dir, to: .transcribed)
                runHook(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                // Recorded as a blocker so the failure is durable and visible,
                // not just a line in a log nobody opens.
                try? SessionState.block(
                    dir, with: .failed(stage: .recorded, message: "\(error)"))
                lastFailure = dir.lastPathComponent
                notifyUser(
                    title: "plume — transcription failed",
                    body: "\(dir.lastPathComponent) — see .plume/transcribe.log"
                )
            }
        }
        await engine?.release()
        engine = nil
        await diarizer?.release()
        diarizer = nil
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    private func transcribe(_ dir: URL) async throws {
        let meta = try SessionMeta.read(from: dir)
        let engine = try await preparedEngine()

        var merged: [Transcript.Segment] = []
        for track in meta.tracks {
            let audio = SessionState.directory(in: dir).appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            // Diarize the far-end track only. The mic track is you by
            // construction — two-track capture gives me/them for free, so
            // diarization only has to split the *remote* participants apart.
            var attributed: [AttributedSegment]
            if track.speaker == .them {
                do {
                    let diarizer = try await preparedDiarizer()
                    let turns = try await diarizer.diarize(audio)
                    let speakers = Set(turns.map(\.speakerId)).count
                    if turns.isEmpty {
                        log(dir, "no speech on \(track.file) — nothing to diarize")
                    } else {
                        log(dir, "diarized \(track.file): \(speakers) speaker(s), \(turns.count) turns")
                    }
                    attributed = SpeakerAttribution.attribute(
                        segments: segments, turns: turns, fallback: track.speaker)
                } catch {
                    // Degrade to Quill's behaviour rather than losing the
                    // transcript: an un-split "them" is still a usable meeting.
                    log(dir, "diarization failed for \(track.file): \(error) — keeping 'them'")
                    attributed = segments.map {
                        AttributedSegment(
                            speaker: track.speaker, start: $0.start, end: $0.end, text: $0.text)
                    }
                }
            } else {
                attributed = segments.map {
                    AttributedSegment(
                        speaker: track.speaker, start: $0.start, end: $0.end, text: $0.text)
                }
            }

            let offset = TimeInterval(track.offsetMs) / 1000
            merged += attributed.map {
                Transcript.Segment(
                    speaker: $0.speaker.label,
                    start_ms: Int(($0.start + offset) * 1000),
                    end_ms: Int(($0.end + offset) * 1000),
                    text: $0.text
                )
            }
        }

        // Both tracks are now on a common clock, which is what the echo filter
        // needs to compare them. Runs before the sort so dropped segments never
        // reach the transcript.
        if Config.echoFilterEnabled() {
            let result = EchoFilter.dropEchoes(merged)
            if result.dropped > 0 {
                log(dir, "echo filter dropped \(result.dropped) mic segment(s) duplicating far-end audio")
            }
            merged = result.segments
        }
        merged = Transcript.sorted(merged)

        // Write meeting.md now, with the summary still pending. Deliberately
        // *before* summarization exists: a failed or never-requested summary
        // must never leave a completed transcript invisible on disk.
        let speakers = orderedSpeakers(in: merged)
        var frontmatter: [(String, String)] = [
            ("plume", "1"),
            ("title", dir.lastPathComponent),
            ("started", Self.localTimestamp(meta.startedAt ?? Date())),
            ("duration_s", "\(meta.durationSeconds ?? 0)"),
            ("engine", "\(engine.name) (\(engine.model))"),
        ]
        // Flat keys, one per *remote* speaker — this map is what Phase 4/5 fill
        // in with real names (speaker_S1: Marie). "me" and "them" are already
        // meaningful labels and need no mapping, so listing them is noise.
        for label in speakers where Speaker.isRemoteLabel(label) {
            frontmatter.append(("speaker_\(label)", label))
        }

        let document = MeetingDocument.render(
            frontmatter: frontmatter,
            notes: readScratchNotes(in: dir),
            summary: "*pending*",
            transcript: Transcript.renderSegments(merged)
        )
        let meetingURL = dir.appendingPathComponent("meeting.md")
        try MeetingDocument.write(document, to: meetingURL)
        log(dir, "wrote meeting.md — \(merged.count) segments, \(speakers.count) speaker(s)")

        // Only now is the audio expendable. Deleting earlier would risk losing
        // the meeting entirely if the write failed; deleting later never happens.
        deleteAudio(in: dir, tracks: meta.tracks.map(\.file))
    }

    /// ISO8601 with the local offset. UTC would render a 10:14 meeting as
    /// 00:14, which reads as a different day to the person who was in it.
    ///
    /// Built per call rather than cached: `ISO8601DateFormatter` is a mutable
    /// class and not `Sendable`, and this runs once per meeting.
    private static func localTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    /// Speaker labels in first-appearance order, for the frontmatter.
    private func orderedSpeakers(in segments: [Transcript.Segment]) -> [String] {
        var seen: [String] = []
        for segment in segments where !seen.contains(segment.speaker) {
            seen.append(segment.speaker)
        }
        return seen
    }

    /// Notes typed during the call (Phase 5 writes these); empty for now.
    private func readScratchNotes(in dir: URL) -> String {
        let url = SessionState.directory(in: dir).appendingPathComponent("notes.md")
        return (try? String(contentsOf: url, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Audio is deleted as soon as the transcript is durably written — a decided
    /// requirement, not an optimisation. There is no re-run: tune against the
    /// held-aside corpus, never against a real meeting (docs/PLAN.md R3).
    private func deleteAudio(in dir: URL, tracks: [String]) {
        let work = SessionState.directory(in: dir)
        for track in tracks {
            let url = work.appendingPathComponent(track)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                log(dir, "could not delete \(track): \(error)")
            }
        }
        log(dir, "audio deleted")
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let configured = Config.transcriptionEngine()
        if configured != "parakeet" {
            FileHandle.standardError.write(Data(
                "warning: unknown transcription engine \"\(configured)\" — using parakeet\n".utf8
            ))
        }
        let engine = ParakeetEngine()
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    /// Lazily loaded alongside the ASR engine, and released on the same drain,
    /// so an idle Plume holds neither set of weights. The diarizer models are
    /// small (~21 MB) next to Parakeet's ~464 MB, but the lifecycle should be
    /// uniform — and at 16 GB the summarizer needs the room (docs/PLAN.md R5).
    private func preparedDiarizer() async throws -> Diarizing {
        if let diarizer { return diarizer }
        let diarizer = OfflineDiarizer(maxSpeakers: Config.maxFarEndSpeakers())
        try await diarizer.prepare()
        self.diarizer = diarizer
        return diarizer
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = SessionState.directory(in: dir).appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
struct SessionMeta {
    struct Track {
        let file: String
        /// The speaker every segment on this track belongs to *before*
        /// diarization. Phase 2 keeps this for the mic track and subdivides the
        /// system track into `.remote(n)`.
        let speaker: Speaker
        let offsetMs: Int
    }

    let tracks: [Track]
    let startedAt: Date?
    let durationSeconds: Int?

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = SessionState.directory(in: dir).appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: .me, offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(
                Track(file: system, speaker: .them, offsetMs: offsets["system"] ?? 0))
        }
        let started = (json["started"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        return SessionMeta(
            tracks: tracks,
            startedAt: started,
            durationSeconds: json["duration_seconds"] as? Int)
    }
}

/// Transcript segments. `meeting.md` is now the only output — transcript.json
/// and transcript.md are gone, since one file per meeting was the point.
struct Transcript {
    struct Segment: Codable, Equatable {
        /// Speaker label as written to disk: "me", "them", or "S1"/"S2"…
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    /// Deterministic order for merged segments.
    ///
    /// Swift's sort is not stable, so ties on `start_ms` would order arbitrarily
    /// and re-running the same session could produce a different transcript.
    /// Diarization multiplies simultaneous starts by splitting one track into
    /// several speakers, so ties are common rather than exotic.
    ///
    /// Lives here rather than inline in the coordinator so the test can exercise
    /// *this* comparator — it used to re-declare an identical closure locally and
    /// therefore passed regardless of what production did.
    static func sorted(_ segments: [Segment]) -> [Segment] {
        segments.sorted { a, b in
            if a.start_ms != b.start_ms { return a.start_ms < b.start_ms }
            if a.end_ms != b.end_ms { return a.end_ms < b.end_ms }
            if a.speaker != b.speaker { return a.speaker < b.speaker }
            return a.text < b.text
        }
    }

    /// Segment lines only — the body of meeting.md's transcript region. The
    /// surrounding document (frontmatter, headings, markers) belongs to
    /// MeetingDocument, so this stays a pure list of lines.
    static func renderSegments(_ segments: [Segment]) -> String {
        segments.map {
            "**[\(clock($0.start_ms))] \($0.speaker):** \($0.text)"
        }.joined(separator: "\n\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
