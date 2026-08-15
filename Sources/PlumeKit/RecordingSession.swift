import Foundation

/// One meeting recording.
///
/// Layout: a timestamped folder whose only visible content is eventually
/// `meeting.md`. Everything transient — the two audio tracks, meta.json, the
/// log, pipeline state — lives in `.plume/` and is removed once the transcript
/// is safely written. The user opens a folder and sees a document, not scaffolding.
///
/// Tracks are separate on purpose: ASR does better on clean single-source audio,
/// and two tracks give me/them separation for free before any model runs.
/// Main-actor isolated: created, started and stopped only by `AppController`,
/// and the liveness watchdog fires on the main run loop. Declaring that makes
/// the class implicitly `Sendable` and removes an unchecked capture, rather than
/// asserting safety at the call site. The audio threads live one level down, in
/// MicRecorder/SystemAudioRecorder, which own their own synchronisation.
@MainActor
final class RecordingSession {
    let dir: URL
    let startedAt = Date()

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()

    // Track-liveness watchdog (cherry-picked from digimata/quill#6). Both .caf
    // files grow continuously while their capture is healthy; a track whose file
    // freezes mid-session — a call app reconfiguring the input device, a died
    // tap, anything — is a recording silently going wrong, and the user should
    // hear about it now rather than after the meeting. Upstream measured a
    // 19-minute call yielding a 1.7s mic track with no visible symptom until the
    // transcript came out one-sided.
    //
    // This is the safety net behind #2's automatic restart: #2 handles the known
    // cause, this catches every other one.
    private var watchdog: Timer?
    private var trackSize: [String: Int64] = [:]
    private var trackLastGrew: [String: Date] = [:]
    private var trackStalled: Set<String> = []
    private static let watchdogInterval: TimeInterval = 15
    private static let stallThreshold: TimeInterval = 45

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        // Hyphenated and sortable. Phase 4 appends a title slug to this
        // (2026-08-14-2215-pricing-review) once one has been derived.
        f.dateFormat = "yyyy-MM-dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy-MM-dd-HHmm, suffixed on
    /// collision) plus its `.plume/` working directory, without starting capture.
    init(root: URL) throws {
        let base = Self.folderFormat.string(from: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
        try FileManager.default.createDirectory(
            at: SessionState.directory(in: candidate), withIntermediateDirectories: true)
    }

    /// Transient working directory: audio, meta, log, pipeline state.
    var workDir: URL { SessionState.directory(in: dir) }

    /// Start both tracks. If the mic fails after the system tap started, the
    /// tap is torn down so we never run half a session silently.
    func start() throws {
        try system.start(writingTo: workDir.appendingPathComponent("system.caf"))
        do {
            try mic.start(writingTo: workDir.appendingPathComponent("mic.caf"))
        } catch {
            system.stop()
            throw error
        }
        // The timer block is `@Sendable`; `assumeIsolated` documents that it
        // fires on the main run loop, where this class already lives.
        watchdog = Timer.scheduledTimer(
            withTimeInterval: Self.watchdogInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkTrackLiveness() }
        }
    }

    /// Stop both tracks and write meta.json.
    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        mic.stop()
        system.stop()

        let ended = Date()
        let iso = ISO8601DateFormatter()

        // The tracks don't start on the same buffer; record how far each
        // lags the earliest so transcript timestamps share one clock.
        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let earliest = min(micStart, systemStart)

        let meta: [String: Any] = [
            "started": iso.string(from: startedAt),
            "ended": iso.string(from: ended),
            "duration_seconds": Int(ended.timeIntervalSince(startedAt)),
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": [
                "mic": Int(micStart.timeIntervalSince(earliest) * 1000),
                "system": Int(systemStart.timeIntervalSince(earliest) * 1000),
            ],
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: workDir.appendingPathComponent("meta.json"))
            // Recording is durably complete; the pipeline can resume from here
            // even if we crash before transcription starts.
            try? SessionState(stage: .recorded).save(to: dir)
        }
    }

    // MARK: -

    /// Compare each track file's size against the last poll. Growth clears any
    /// stall state (and announces recovery); a freeze past the threshold
    /// notifies once per stall episode, so a track that dies, recovers, and
    /// dies again alerts both times without spamming in between.
    private func checkTrackLiveness() {
        let now = Date()
        for name in ["mic", "system"] {
            let path = workDir.appendingPathComponent("\(name).caf").path
            guard let size = (try? FileManager.default
                .attributesOfItem(atPath: path))?[.size] as? Int64 else { continue }

            if size != trackSize[name] {
                trackSize[name] = size
                trackLastGrew[name] = now
                if trackStalled.remove(name) != nil {
                    notifyUser(
                        title: "Plume: \(name) track recovered",
                        body: "\(name) audio is being written again."
                    )
                }
            } else if let last = trackLastGrew[name], !trackStalled.contains(name),
                      now.timeIntervalSince(last) >= Self.stallThreshold {
                trackStalled.insert(name)
                notifyUser(
                    title: "Plume: \(name) track stalled",
                    body: "No \(name) audio written for \(Int(now.timeIntervalSince(last)))s"
                        + " — the recording may be incomplete."
                )
            }
        }
    }
}
