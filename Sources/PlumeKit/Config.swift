import Foundation

/// Typed view of `~/.config/plume/config.json`.
///
/// Every field is optional so that absent keys stay absent when the settings
/// window rewrites the file — writing materialised defaults would turn an
/// "unset, follow the app default" into a pin that survives future changes.
struct Settings: Codable, Sendable, Equatable {
    struct Transcription: Codable, Sendable, Equatable {
        var enabled: Bool?
        var engine: String?
    }

    var recordingsDir: String?
    var onStop: String?
    var micVoiceProcessing: Bool?
    var transcriptEchoFilter: Bool?
    var expectedParticipants: Int?
    var callDetection: Bool?
    var updateCheck: Bool?
    var summaryModel: String?
    var summaryContextTokens: Int?
    var defaultTemplate: String?
    var transcription: Transcription?

    enum CodingKeys: String, CodingKey {
        case recordingsDir = "recordings_dir"
        case onStop = "on_stop"
        case micVoiceProcessing = "mic_voice_processing"
        case transcriptEchoFilter = "transcript_echo_filter"
        case expectedParticipants = "expected_participants"
        case callDetection = "call_detection"
        case updateCheck = "update_check"
        case summaryModel = "summary_model"
        case summaryContextTokens = "summary_context_tokens"
        case defaultTemplate = "default_template"
        case transcription
    }
}

/// Optional user config at ~/.config/plume/config.json:
///
///     {
///       "recordings_dir": "~/Meetings",
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the meetings root: config file > ~/Meetings.
/// `on_stop` is a shell command spawned with the session directory as its
/// argument — after the transcript is written, or right after recording when
/// transcription is disabled.
///
/// The file is the single source of truth: the settings window reads and writes
/// it, so a hand-edit and a UI edit can never disagree.
enum Config {
    /// Overridable **only** so tests can point it somewhere disposable.
    ///
    /// It was a `let`, and that single fact is why the two most valuable
    /// regression tests here did not exist: any test that exercised
    /// `current()` / `save()` would read and rewrite the developer's real
    /// config. `withPath` restores the previous value, so a test cannot leak
    /// its temp path into the next one.
    static var path: URL { pathOverride ?? defaultPath }

    /// A **task-local**, not a lock and not a mutable global.
    ///
    /// Swift 6 rejects the mutable global, and AGENTS.md §4 rules out an
    /// `@unchecked Sendable`. A lock compiles, but it is still process-wide —
    /// and Swift Testing runs tests in parallel, so one test's temp path became
    /// another suite's answer. Measured, not predicted: `ConfigTests` failed on
    /// the first run with this override held by a concurrently-running test. A
    /// task-local is scoped to the task tree that sets it, which is exactly the
    /// scope a test needs.
    @TaskLocal private static var pathOverride: URL?

    static let defaultPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/plume/config.json")

    /// Run `body` against a different config file. Test-only by intent; it also
    /// drops the mtime cache on both sides, since two files' modification dates
    /// are not comparable.
    static func withPath<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        cache.invalidate()
        defer { cache.invalidate() }
        return try $pathOverride.withValue(url) { try body() }
    }

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Meetings", isDirectory: true)

    // MARK: - Accessors

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = current().recordingsDir, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = current().onStop, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    /// Deliberately **not** in the settings window. Off, a recording stops at
    /// `recorded` forever: no transcript, no summary, no meeting.md — the whole
    /// app does nothing, from a toggle that reads like an ordinary preference.
    /// It survives as a config key because Quill's CLI has a legitimate
    /// record-only mode; a hand-edit still honours it.
    static func transcriptionEnabled() -> Bool {
        current().transcription?.enabled ?? true
    }

    /// Notify when the camera turns on and Plume isn't recording. **Default
    /// off**: it fires on any camera use, including the ones that are not
    /// meetings, and a notification nobody asked for is worse than a missed
    /// reminder. Opt in from Settings.
    static func callDetectionEnabled() -> Bool {
        current().callDetection ?? false
    }

    /// Ask GitHub once a day whether a newer release exists. **Default on**,
    /// which is the one default here that trades a privacy claim for a
    /// functional one: outside the App Store nothing else will ever tell you an
    /// update exists, and a stale install is its own risk. It is the only
    /// non-localhost request Plume makes after the first-run model download, so
    /// the README names it, and off means no request is made at all rather than
    /// a result that is discarded.
    static func updateCheckEnabled() -> Bool {
        current().updateCheck ?? true
    }

    /// Configured engine name. Only "parakeet" ships today; the coordinator
    /// warns and falls back for anything else.
    static func transcriptionEngine() -> String {
        current().transcription?.engine ?? "parakeet"
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        current().micVoiceProcessing ?? false
    }

    /// Drop mic segments that duplicate far-end speech. Default on: it costs
    /// nothing when there is no echo, and echo is the norm when a meeting plays
    /// through speakers. Set false to inspect the raw merge.
    static func echoFilterEnabled() -> Bool {
        current().transcriptEchoFilter ?? true
    }

    /// Typical number of people in a meeting, including you. Default 2 — a 1:1.
    ///
    /// The mic track is you by construction, so the far-end track holds
    /// `expected - 1` speakers. That bound is handed to the diarizer, which
    /// makes over-splitting structurally impossible rather than merely unlikely.
    /// Set 0 to leave the diarizer unconstrained.
    static func expectedParticipants() -> Int {
        current().expectedParticipants ?? 2
    }

    /// Upper bound on far-end speakers, or nil for unconstrained.
    static func maxFarEndSpeakers() -> Int? {
        let expected = expectedParticipants()
        guard expected > 0 else { return nil }
        return Swift.max(1, expected - 1)
    }

    /// Ollama model used for summaries.
    static func summaryModel() -> String {
        current().summaryModel ?? "gemma4:latest"
    }

    /// Context window requested from Ollama. 32768 measured in Spike C at
    /// 552 MiB of KV cache — cheap enough that a one-hour meeting summarizes in
    /// a single pass, which avoids losing context across map-reduce windows.
    static func summaryContextTokens() -> Int {
        current().summaryContextTokens ?? 32768
    }

    /// Template id used when none is chosen for a meeting.
    static func defaultTemplate() -> String {
        current().defaultTemplate ?? "general"
    }


    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }

    // MARK: - Load / store

    /// Cached parse, invalidated by the file's modification date — Quill
    /// re-read and re-parsed on *every* accessor call, including from inside an
    /// actor, i.e. blocking disk I/O on a cooperative-pool thread. See
    /// `MTimeCache` for why all three hand-editable stores cache this way.
    private static let cache = MTimeCache<Date, Settings>()

    /// Current settings, or all-nil defaults when there is no readable config.
    static func current() -> Settings {
        cache.value {
            (try? FileManager.default.attributesOfItem(atPath: path.path))?[.modificationDate]
                as? Date
        } compute: {
            guard
                let data = try? Data(contentsOf: path),
                let settings = try? JSONDecoder().decode(Settings.self, from: data)
            else {
                // A missing file is the normal case and says nothing. A file
                // that exists and doesn't parse is reported rather than
                // silently ignored: recordings landing in an unexpected place
                // is worse than a warning.
                if FileManager.default.fileExists(atPath: path.path) {
                    FileHandle.standardError.write(Data(
                        "warning: \(path.path) is not valid Plume config — ignoring\n".utf8
                    ))
                }
                return Settings()
            }
            return settings
        }
    }

    /// Apply a change to the config file. Read-modify-write against the file so
    /// keys Plume doesn't know about are preserved.
    static func update(_ mutate: (inout Settings) -> Void) throws {
        var settings = current()
        mutate(&settings)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: path, options: .atomic)
        // Drop the cache: filesystem mtime resolution can round our write away.
        cache.invalidate()
    }
}
