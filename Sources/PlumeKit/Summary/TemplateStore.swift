import Foundation

/// A summary template: a name and the system prompt that produces it.
struct SummaryTemplate: Sendable, Equatable {
    let id: String
    let name: String
    let prompt: String
}

/// Templates are **markdown files in a folder**, not a JSON store.
///
/// Everything else in Plume is a markdown file you own and edit in your own
/// editor; prompts should be no different. The file body *is* the system prompt,
/// with frontmatter carrying the display name. Adding a template is dropping a
/// file in; editing one is opening it. That deletes the whole built-in
/// reconciliation machinery a JSON store needs — and keeps the picker honest,
/// since it just lists the directory.
enum TemplateStore {

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Plume/Templates", isDirectory: true)
    }

    /// Shipped on first run and never overwritten afterwards, so edits survive
    /// updates. Three is enough; six was OpenOats' number and most went unused.
    static let seeds: [SummaryTemplate] = [
        SummaryTemplate(
            id: "general",
            name: "General",
            prompt: """
                You are summarizing a meeting transcript for the person who attended it.

                Write in Markdown, using only these sections, and omit any that have no content:

                ## Summary
                Two to four sentences on what the meeting was actually about.

                ## Decisions
                Only things that were actually decided. If nothing was, omit the section.

                ## Actions
                One bullet per commitment, in the form `- [ ] Owner — what, by when`.
                Use the speaker label if you don't know a real name. Omit dates that were
                never stated rather than inventing them.

                ## Open questions
                Things raised and left unresolved.

                Rules:
                - Only use what is in the transcript and notes. Never invent a decision,
                  a name, a number or a date.
                - If the transcript is too garbled or too short to summarize, say so plainly
                  instead of producing a plausible-sounding summary.
                - Prefer the attendee's own notes where they conflict with the transcript;
                  they were there and the transcript may have misheard.
                """),
        SummaryTemplate(
            id: "one-to-one",
            name: "1:1",
            prompt: """
                You are summarizing a one-to-one conversation for one of the two people in it.

                Write in Markdown, omitting any section with no content:

                ## Summary
                Two to four sentences on what was discussed.

                ## Agreed
                What both people committed to, one bullet each.

                ## To follow up
                `- [ ] Owner — what` for anything left open.

                ## Worth remembering
                Personal or contextual details worth carrying into the next conversation —
                only if actually mentioned.

                Rules:
                - Only use what is in the transcript and notes. Never invent anything.
                - Keep it short. A 1:1 summary longer than the notes has failed.
                - Say plainly if the transcript is too thin to summarize.
                """),
        SummaryTemplate(
            id: "standup",
            name: "Stand-up",
            prompt: """
                You are summarizing a status meeting.

                Write in Markdown:

                ## Updates
                One bullet per person, using their speaker label if you don't know a name.

                ## Blockers
                Only genuine blockers that were raised.

                ## Actions
                `- [ ] Owner — what, by when`, omitting dates that were never stated.

                Rules:
                - Only use what is in the transcript and notes. Never invent anything.
                - Omit any section with no content rather than writing "none".
                - Be terse. This is a status summary, not prose.
                """),
    ]

    /// Write any seed template that isn't already on disk. Existing files are
    /// never touched, so a hand-edited prompt survives every future launch.
    @discardableResult
    static func seedIfNeeded() throws -> [String] {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        var written: [String] = []
        for template in seeds {
            let url = directory.appendingPathComponent("\(template.id).md")
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try render(template).write(to: url, atomically: true, encoding: .utf8)
            written.append(template.id)
        }
        return written
    }

    static func render(_ template: SummaryTemplate) -> String {
        """
        ---
        name: \(template.name)
        ---

        \(template.prompt)
        """
    }

    /// Parse one template file. The body after the frontmatter is the prompt.
    static func parse(_ contents: String, id: String) -> SummaryTemplate? {
        let pairs = MeetingDocument.frontmatter(in: contents)
        let name = pairs.first(where: { $0.0 == "name" })?.1 ?? id

        var body = contents
        if contents.hasPrefix("---") {
            let lines = contents.components(separatedBy: "\n")
            if let close = lines.dropFirst().firstIndex(of: "---") {
                body = lines[(close + 1)...].joined(separator: "\n")
            }
        }
        let prompt = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        return SummaryTemplate(id: id, name: name, prompt: prompt)
    }

    /// Every template in the folder, sorted by display name.
    static func all() -> [SummaryTemplate] {
        try? seedIfNeeded()
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return seeds }

        let parsed = files
            .filter { $0.pathExtension == "md" }
            .compactMap { url -> SummaryTemplate? in
                guard let contents = try? String(contentsOf: url, encoding: .utf8)
                else { return nil }
                return parse(contents, id: url.deletingPathExtension().lastPathComponent)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // A folder emptied by hand shouldn't leave summarization impossible.
        return parsed.isEmpty ? seeds : parsed
    }

    static func template(id: String) -> SummaryTemplate? {
        all().first { $0.id == id }
    }

    /// The template used when none is chosen.
    static func `default`() -> SummaryTemplate {
        template(id: Config.defaultTemplate()) ?? all().first ?? seeds[0]
    }
}
