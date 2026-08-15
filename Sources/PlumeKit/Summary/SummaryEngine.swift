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

    private let client: OllamaClient

    init(client: OllamaClient = OllamaClient()) {
        self.client = client
    }

    struct Progress: Sendable {
        var partial: String
        var windowsDone: Int
        var windowsTotal: Int
    }

    /// Summarize a session and write the result into its `meeting.md`.
    ///
    /// - Parameter onProgress: called with the accumulating text so a UI can
    ///   show it arriving. Never used to write to disk.
    func summarize(
        session: URL,
        template: SummaryTemplate,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws {
        let meetingURL = session.appendingPathComponent("meeting.md")
        let document = try String(contentsOf: meetingURL, encoding: .utf8)

        let transcript = try MeetingDocument.read(.transcript, from: document)
        let notes = try MeetingDocument.read(.notes, from: document)

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummaryError.emptyTranscript
        }

        let summary = try await generate(
            transcript: transcript, notes: notes, template: template,
            onProgress: onProgress)

        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SummaryError.emptyResponse }

        // Only now does anything touch the file. Re-reads inside updateRegion,
        // so edits made while the model was running survive.
        try MeetingDocument.updateRegion(.summary, at: meetingURL, to: trimmed)
        try stampFrontmatter(at: meetingURL, template: template)

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
    }

    /// Apply the title (safe — it labels the meeting) and leave speaker names as
    /// proposals (invariant 3 — they attribute speech and need a human click).
    /// Returns the session URL, which changes if the folder was renamed.
    private func apply(_ identity: MeetingIdentity, to session: URL) throws -> URL {
        guard let title = identity.title, !title.isEmpty else { return session }

        let meetingURL = session.appendingPathComponent("meeting.md")
        let document = try String(contentsOf: meetingURL, encoding: .utf8)
        var pairs = MeetingDocument.frontmatter(in: document)
        if let index = pairs.firstIndex(where: { $0.0 == "title" }) {
            pairs[index] = ("title", title)
        }
        guard let end = document.range(of: "\n---\n") else { return session }
        try MeetingDocument.write(
            MeetingDocument.renderFrontmatter(pairs) + String(document[end.upperBound...]),
            to: meetingURL)

        // Rename the folder to carry the title. Safe here: recording finished
        // long ago, the audio is deleted, and nothing holds the directory open.
        let slug = MeetingIdentityDeriver.slug(title)
        guard !slug.isEmpty else { return session }
        let stamp = session.lastPathComponent.prefix(15)  // yyyy-MM-dd-HHmm
        let renamed = session.deletingLastPathComponent()
            .appendingPathComponent("\(stamp)-\(slug)", isDirectory: true)
        guard renamed != session,
            !FileManager.default.fileExists(atPath: renamed.path)
        else { return session }
        do {
            try FileManager.default.moveItem(at: session, to: renamed)
            return renamed
        } catch {
            // A failed rename is cosmetic; the timestamp name is perfectly good.
            return session
        }
    }

    // MARK: - Generation

    private func generate(
        transcript: String, notes: String, template: SummaryTemplate,
        onProgress: (@Sendable (Progress) -> Void)?
    ) async throws -> String {
        // Try the whole meeting in one pass. At num_ctx 32768 an hour-long
        // meeting fits, and a single pass has no seams to lose context across.
        do {
            return try await stream(
                system: template.prompt,
                user: Prompt.single(transcript: transcript, notes: notes),
                onProgress: { onProgress?(Progress(partial: $0, windowsDone: 0, windowsTotal: 1)) })
        } catch OllamaClient.ClientError.contextExceeded(let promptTokens, let contextTokens) {
            // Only now do we chunk, and we size the windows from the counts
            // Ollama just reported rather than guessing.
            return try await mapReduce(
                transcript: transcript, notes: notes, template: template,
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
        transcript: String, notes: String, template: SummaryTemplate,
        promptTokens: Int, contextTokens: Int,
        onProgress: (@Sendable (Progress) -> Void)?
    ) async throws -> String {
        let windows = Prompt.split(
            transcript: transcript, promptTokens: promptTokens, contextTokens: contextTokens)
        var digests: [String] = []

        for (index, window) in windows.enumerated() {
            let digest = try await stream(
                system: Prompt.windowSystem,
                user: Prompt.window(
                    window, index: index, of: windows.count, prior: digests.last),
                onProgress: { partial in
                    onProgress?(Progress(
                        partial: partial, windowsDone: index, windowsTotal: windows.count))
                })
            digests.append(digest.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return try await stream(
            system: template.prompt,
            user: Prompt.reduce(digests: digests, notes: notes),
            onProgress: { onProgress?(Progress(
                partial: $0, windowsDone: windows.count, windowsTotal: windows.count)) })
    }

    /// Accumulate a streamed response in memory. Nothing is written until the
    /// stream completes — invariant 2.
    private func stream(
        system: String, user: String, onProgress: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        var buffer = ""
        for try await delta in client.stream(system: system, user: user) {
            buffer += delta
            onProgress(buffer)
        }
        return buffer
    }

    // MARK: - Frontmatter

    private func stampFrontmatter(at url: URL, template: SummaryTemplate) throws {
        let document = try String(contentsOf: url, encoding: .utf8)
        var pairs = MeetingDocument.frontmatter(in: document)

        func set(_ key: String, _ value: String) {
            if let index = pairs.firstIndex(where: { $0.0 == key }) {
                pairs[index] = (key, value)
            } else {
                pairs.append((key, value))
            }
        }
        set("template", template.id)
        set("model", client.model)
        set("summary_generated", ISO8601DateFormatter().string(from: Date()))

        // Replace only the frontmatter block, leaving every region untouched.
        guard let end = document.range(of: "\n---\n", range: document.startIndex..<document.endIndex)
        else { return }
        let rebuilt = MeetingDocument.renderFrontmatter(pairs)
            + String(document[end.upperBound...])
        try MeetingDocument.write(rebuilt, to: url)
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
