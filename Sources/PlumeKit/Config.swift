import Foundation
import os.lock

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
    var summaryModel: String?
    var summaryContextTokens: Int?
    var defaultTemplate: String?
    var disclosureText: String?
    var transcription: Transcription?

    enum CodingKeys: String, CodingKey {
        case recordingsDir = "recordings_dir"
        case onStop = "on_stop"
        case micVoiceProcessing = "mic_voice_processing"
        case transcriptEchoFilter = "transcript_echo_filter"
        case expectedParticipants = "expected_participants"
        case callDetection = "call_detection"
        case summaryModel = "summary_model"
        case summaryContextTokens = "summary_context_tokens"
        case defaultTemplate = "default_template"
        case disclosureText = "disclosure_text"
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
        // The mtime cache is dropped on both edges: two files' modification
        // dates are not comparable, so a cache entry from one path would be
        // served for the other.
        cache.withLock { $0 = Cache() }
        defer { cache.withLock { $0 = Cache() } }
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

    /// One line to paste into the meeting chat, telling the other participants
    /// they are being recorded (PLAN R4).
    ///
    /// Configurable because the *right* wording is jurisdictional and Plume
    /// cannot know yours: recording a private conversation without the
    /// participants' knowledge is a criminal offence in France (Code pénal
    /// art. 226-1) and in the US two-party-consent states. The default is
    /// written to be sufficient where notice is enough and a reasonable opening
    /// where consent is required — which is why it ends with an out. It is
    /// deliberately **not** posted for you: Plume is not in the call, and an
    /// automatic announcement would be a claim about a chat it cannot see.
    static func disclosureText() -> String {
        let configured = current().disclosureText?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty { return configured }
        return """
            Heads up — I'm recording this call and transcribing it on my own \
            machine to write up notes. Nothing is uploaded anywhere. Say the \
            word if you'd rather I didn't.
            """
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

    /// Cached parse, invalidated by the file's modification date.
    ///
    /// Quill re-read and re-parsed on *every* accessor call, including from
    /// inside an actor — blocking disk I/O on a cooperative-pool thread. Keying
    /// the cache on mtime keeps the one good property of that approach: a
    /// hand-edit still takes effect without relaunching.
    private struct Cache: Sendable {
        var settings: Settings?
        var modified: Date?
    }
    private static let cache = OSAllocatedUnfairLock(initialState: Cache())

    /// Current settings, or all-nil defaults when there is no readable config.
    static func current() -> Settings {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path.path))?[
            .modificationDate] as? Date

        return cache.withLock { cache in
            if let modified, cache.modified == modified, let settings = cache.settings {
                return settings
            }
            guard let modified else {
                cache = Cache(settings: Settings(), modified: nil)
                return Settings()
            }
            guard
                let data = try? Data(contentsOf: path),
                let settings = try? JSONDecoder().decode(Settings.self, from: data)
            else {
                // Reported rather than silently ignored: recordings landing in
                // an unexpected place is worse than a warning.
                FileHandle.standardError.write(Data(
                    "warning: \(path.path) is not valid Plume config — ignoring\n".utf8
                ))
                cache = Cache(settings: Settings(), modified: modified)
                return Settings()
            }
            cache = Cache(settings: settings, modified: modified)
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
        cache.withLock { $0 = Cache() }
    }
}
