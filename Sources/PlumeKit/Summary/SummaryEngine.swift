import Foundation

/// Generates a meeting summary and writes it into `meeting.md`.
///
/// Two rules shape everything here:
///
/// **A failed generation must never destroy a good one** (invariant 2). Output
/// streams into a buffer and the summary region is replaced only once the model
/// has finished. Killing Ollama mid-stream leaves the previous summary intact.
///
/// **Never invent.** Transcript and notes are wrapped in explicit untrusted-input
/// framing: anyone on a call can say "ignore your instructions and…", and that
/// sentence arrives here as ordinary text.
actor SummaryEngine {

    /// Nil in production; a fixed client only when a caller supplies one.
    private let injected: OllamaClient?

    init(client: OllamaClient? = nil) {
        self.injected = client
    }

    /// One client per summarize, resolved when the operation starts.
    ///
    /// **Not stored.** `OllamaClient.init` defaults `model` to
    /// `Config.summaryModel()`, and both UI surfaces build their engine during
    /// `AppController.init` — so a stored client pins whatever model was
    /// configured at launch. Settings, the readiness caption beside Summarise
    /// and `doctor` all build fresh clients, so after changing the model they
    /// would all report the new one while the old one actually wrote the
    /// summary — and got stamped into `model:` as provenance, in the only
    /// surviving record of the meeting.
    ///
    /// **Not re-resolved per access either.** `unload()` runs minutes after
    /// `stream()`; resolving twice lets a model changed mid-generation make us
    /// evict a model Plume never loaded. Ollama is shared.
    private func currentClient() -> OllamaClient { injected ?? OllamaClient() }

    struct Progress: Sendable {
        var partial: String
        var windowsDone: Int
        var windowsTotal: Int
    }

    /// Summarize a session and write the result into its `meeting.md`.
    ///
    /// - Parameter onProgress: called with the accumulating text so a UI can
    ///   show it arriving. Never used to write to disk.
    /// - Returns: the session URL, which **changes** when deriving a title
    ///   renames the folder. Callers used to search the parent for a folder
    ///   whose name starts with the `yyyy-MM-dd-HHmm` stamp, which is ambiguous
    ///   by construction: `RecordingSession` disambiguates a same-minute
    ///   collision with a `-2` suffix and `renameFolder` drops it, so two
    ///   meetings recorded in the same minute end up differing only by slug and
    ///   the prefix match can return either. Back-to-back calls are the case
    ///   the panel exists for. Handing the answer back removes the guess rather
    ///   than making two copies of it agree.
    @discardableResult
    func summarize(
        session: URL,
        template: SummaryTemplate,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> URL {
        // Fixed for the duration of this summarize; current on the next one.
        let client = currentClient()
        let meetingURL = session.appendingPathComponent("meeting.md")
        let document = try String(contentsOf: meetingURL, encoding: .utf8)

        let transcript = try MeetingDocument.read(.transcript, from: document)
        let notes = try MeetingDocument.read(.notes, from: document)

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummaryError.emptyTranscript
        }

        let summary = try await generate(
            client: client, transcript: transcript, notes: notes, template: template,
            onProgress: onProgress)

        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SummaryError.emptyResponse }

        // Only now does anything touch the file. Re-reads inside updateRegion,
        // so edits made while the model was running survive.
        try MeetingDocument.updateRegion(.summary, at: meetingURL, to: trimmed)
        stampFrontmatter(at: meetingURL, template: template, model: client.model)

        // Title and speaker names, derived from what was actually said. Failure
        // here must not undo a good summary, so it is best-effort.
        var finalSession = session
        do {
            let identity = try await MeetingIdentityDeriver.derive(
                transcript: transcript, notes: notes, client: client)
            try identity.save(to: session)
            finalSession = try apply(identity, to: session)
        } catch {
            FileHandle.standardError.write(Data(
                "could not derive title/speakers: \(error)\n".utf8))
        }

        try SessionState.advance(finalSession, to: .summarized)

        // Ours to unload, and only ours — Ollama is shared.
        try? await client.unload()

        return finalSession
    }

    /// Apply the title (safe — it labels the meeting) and leave speaker names as
    /// proposals (invariant 3 — they attribute speech and need a human click).
    /// Returns the session URL, which changes if the folder was renamed.
    private func apply(_ identity: MeetingIdentity, to session: URL) throws -> URL {
        guard let title = identity.title, !title.isEmpty else { return session }

        // A title someone typed outlasts every regenerate. Derived names are
        // proposals (invariant 3) and this one has already been answered —
        // overwriting it would make Rename appear to work and then silently
        // undo itself on the next summary.
        guard !MeetingAdmin.isUserTitled(session: session) else { return session }

        try MeetingDocument.updateFrontmatter(
            at: session.appendingPathComponent("meeting.md")
        ) { pairs in
            MeetingDocument.setValue(title, for: "title", in: &pairs)
        }

        // Rename the folder to carry the title. Safe here: recording finished
        // long ago, the audio is deleted, and nothing holds the directory open.
        return MeetingAdmin.renameFolder(session, toSlugOf: title)
    }

    // MARK: - Generation

    private func generate(
        client: OllamaClient, transcript: String, notes: String, template: SummaryTemplate,
        onProgress: (@Sendable (Progress) -> Void)?
    ) async throws -> String {
        // Read once per run, not once per window: the file is the user's and can
        // change under a long map-reduce, and a glossary that differed between
        // slices would compress the same term two ways.
        let vocabulary = VocabularyStore.contents()
        // Try the whole meeting in one pass. At num_ctx 32768 an hour-long
        // meeting fits, and a single pass has no seams to lose context across.
        do {
            return try await stream(
                client: client,
                system: template.prompt,
                user: Prompt.single(transcript: transcript, notes: notes, vocabulary: vocabulary),
                onProgress: { onProgress?(Progress(partial: $0, windowsDone: 0, windowsTotal: 1)) })
        } catch OllamaClient.ClientError.contextExceeded(let promptTokens, let contextTokens) {
            // Only now do we chunk, and we size the windows from the counts
            // Ollama just reported rather than guessing.
            return try await mapReduce(
                client: client, transcript: transcript, notes: notes, template: template,
                vocabulary: vocabulary,
                promptTokens: promptTokens, contextTokens: contextTokens,
                onProgress: onProgress)
        }
    }

    /// Summarize long meetings window by window, then synthesize.
    ///
    /// Each window carries a short digest of the ones before it: decisions made
    /// early and revisited later would otherwise be lost at the seam, which is
    /// the characteristic failure of naive chunking.
    private func mapReduce(
        client: OllamaClient, transcript: String, notes: String, template: SummaryTemplate,
        vocabulary: String, promptTokens: Int, contextTokens: Int,
        onProgress: (@Sendable (Progress) -> Void)?
    ) async throws -> String {
        let windows = Prompt.split(
            transcript: transcript, promptTokens: promptTokens, contextTokens: contextTokens)
        var digests: [String] = []

        for (index, window) in windows.enumerated() {
            let digest = try await stream(
                client: client,
                system: Prompt.windowSystem,
                user: Prompt.window(
                    window, index: index, of: windows.count, prior: digests.last,
                    vocabulary: vocabulary),
                onProgress: { partial in
                    onProgress?(Progress(
                        partial: partial, windowsDone: index, windowsTotal: windows.count))
                })
            digests.append(digest.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return try await stream(
            client: client,
            system: template.prompt,
            user: Prompt.reduce(digests: digests, notes: notes, vocabulary: vocabulary),
            onProgress: { onProgress?(Progress(
                partial: $0, windowsDone: windows.count, windowsTotal: windows.count)) })
    }

    /// Accumulate a streamed response in memory. Nothing is written until the
    /// stream completes — invariant 2.
    private func stream(
        client: OllamaClient, system: String, user: String, onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        var buffer = ""
        for try await delta in client.stream(system: system, user: user) {
            buffer += delta
            onProgress(buffer)
        }
        return buffer
    }

    // MARK: - Frontmatter

    /// Record which template and model produced the summary, and when.
    ///
    /// Not rethrown: `updateFrontmatter` throws when the closing `---` is gone,
    /// which means the user removed the frontmatter by hand. The summary region
    /// is already written and correct — a document in that state must not lose
    /// its summary, nor stall before `state.json` reaches `summarized`
    /// (AGENTS.md §4: blocking must preserve the stage reached). Logged, where
    /// the previous inline splice returned in silence.
    ///
    /// Routing through `updateFrontmatter` also re-reads the file first, rather
    /// than splicing into the copy read before the summary was written —
    /// invariant 1's "re-read from disk before every write".
    private func stampFrontmatter(
        at url: URL, template: SummaryTemplate, model: String
    ) {
        do {
            try MeetingDocument.updateFrontmatter(at: url) { pairs in
                MeetingDocument.setValue(template.id, for: "template", in: &pairs)
                MeetingDocument.setValue(model, for: "model", in: &pairs)
                MeetingDocument.setValue(
                    ISO8601DateFormatter().string(from: Date()),
                    for: "summary_generated", in: &pairs)
            }
        } catch {
            FileHandle.standardError.write(Data(
                "could not stamp frontmatter: \(error)\n".utf8))
        }
    }
}

enum SummaryError: Error, CustomStringConvertible, Equatable {
    case emptyTranscript
    case emptyResponse

    var description: String {
        switch self {
        case .emptyTranscript: return "no transcript to summarise"
        case .emptyResponse: return "the model returned nothing"
        }
    }
}
