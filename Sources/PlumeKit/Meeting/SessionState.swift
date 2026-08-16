import Foundation

/// Durable pipeline state for one meeting, at `.plume/state.json`.
///
/// Replaces Quill's sentinel, which was literally "`meta.json` exists and
/// `transcript.json` does not". That worked when there was exactly one step and
/// one output file. It breaks here for two reasons: `transcript.json` is gone,
/// and summarization is a *second* failable step that happens after the audio
/// has been deleted — so "transcribed but not summarized" must be a resumable
/// resting state rather than an error or a dead end.
struct SessionState: Codable, Equatable, Sendable {

    /// Only states that are durable and distinguishable on disk.
    ///
    /// `transcribed` is the plan's `awaiting_wrapup`: `meeting.md` exists with a
    /// full transcript and `*pending*` summary, and it can sit there
    /// indefinitely by design — closing the laptop after a call is normal, not a
    /// failure. Diarization is deliberately *not* its own stage: when it fails
    /// the pipeline degrades to `them` and continues, so it never leaves a
    /// distinct state to resume from.
    enum Stage: String, Codable, Sendable, CaseIterable, Comparable {
        case recorded
        case transcribed
        case summarized

        private var order: Int {
            switch self {
            case .recorded: return 0
            case .transcribed: return 1
            case .summarized: return 2
            }
        }
        static func < (a: Stage, b: Stage) -> Bool { a.order < b.order }
    }

    /// Why a session isn't progressing. Distinct from "not done yet".
    enum Blocker: Codable, Equatable, Sendable {
        /// Something went wrong and a retry is plausible.
        case failed(stage: Stage, message: String)
        /// The user must act — retrying by itself will not help.
        case needsPermission(String)
        /// Deliberately abandoned; do not keep offering it.
        case cancelled

        var isRetryable: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// On-disk format this build writes and understands.
    ///
    /// Bump when a change would make an *older* Plume misread a file a newer one
    /// wrote — a new stage, a changed blocker shape, a key whose meaning moved.
    /// Adding a key an older build simply ignores does not need a bump; that is
    /// what `Codable`'s optionals already tolerate.
    static let formatVersion = 1

    var stage: Stage
    var blocker: Blocker?
    var updated: Date

    /// The Mac that recorded this session, when known. Only meaningful if the
    /// meetings root is a synced folder — see `isOwnedByThisMachine`. Optional
    /// because sessions recorded before this existed have no stamp.
    var machine: String?

    /// Format that wrote this file. `nil` means it predates versioning, which is
    /// version 1 by definition — the same tolerance `machine` gets, and for the
    /// same reason: files written before the field existed must not be stranded.
    var version: Int?

    init(
        stage: Stage = .recorded,
        blocker: Blocker? = nil,
        updated: Date = Date(),
        machine: String? = MachineID.current,
        version: Int? = SessionState.formatVersion
    ) {
        self.stage = stage
        self.blocker = blocker
        self.updated = updated
        self.machine = machine
        self.version = version
    }

    /// Whether this machine may do unattended work on the session.
    ///
    /// Unstamped sessions pass: they predate the stamp, and on the overwhelmingly
    /// common single-Mac setup there is nothing to protect them from. A stamp
    /// naming *another* Mac fails — that session's audio belongs to a machine
    /// that may still be uploading it, and transcription deletes the audio.
    var isOwnedByThisMachine: Bool {
        machine == nil || machine == MachineID.current
    }

    /// Whether this build understands the file well enough to act on it.
    ///
    /// Forward tolerance is deliberately asymmetric. Reading a file from an
    /// *older* Plume is fine — that is what the optional fields are for. Acting
    /// on one from a *newer* Plume is not: we would be guessing at a stage
    /// machine we don't know, and the first thing this pipeline does on a
    /// `recorded` session is transcribe it and **delete the audio** (invariant
    /// 6). Doing nothing is always recoverable; that deletion never is.
    var isReadableByThisVersion: Bool {
        (version ?? Self.formatVersion) <= Self.formatVersion
    }

    /// Work remains and nothing is standing in the way.
    var isReadyForWork: Bool {
        guard isReadableByThisVersion else { return false }
        guard stage < .summarized else { return false }
        switch blocker {
        case nil: return true
        // A failed stage is retried on the next launch; a permission problem or
        // a deliberate cancel is not, because retrying changes nothing.
        case .failed: return true
        case .needsPermission, .cancelled: return false
        }
    }

    /// Transcribed but never summarized — normal, and the state the UI should
    /// surface as "pending" rather than treat as an error.
    var isAwaitingSummary: Bool {
        stage == .transcribed && blocker == nil
    }

    // MARK: - Persistence

    static let directoryName = ".plume"
    static let fileName = "state.json"

    static func directory(in session: URL) -> URL {
        session.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func url(in session: URL) -> URL {
        directory(in: session).appendingPathComponent(fileName)
    }

    static func load(from session: URL) -> SessionState? {
        guard let data = try? Data(contentsOf: url(in: session)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionState.self, from: data)
    }

    func save(to session: URL) throws {
        try FileManager.default.createDirectory(
            at: Self.directory(in: session), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: Self.url(in: session), options: .atomic)
    }

    /// Record progress. Advancing clears any blocker — the thing that was stuck
    /// evidently succeeded.
    static func advance(_ session: URL, to stage: Stage) throws {
        var state = load(from: session) ?? SessionState()
        state.stage = stage
        state.blocker = nil
        state.updated = Date()
        try state.save(to: session)
    }

    /// Record a blocker without losing the stage already reached.
    static func block(_ session: URL, with blocker: Blocker) throws {
        var state = load(from: session) ?? SessionState()
        state.blocker = blocker
        state.updated = Date()
        try state.save(to: session)
    }
}
