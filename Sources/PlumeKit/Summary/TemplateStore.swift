import Foundation
import os

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
    /// updates. Four; six was OpenOats' number and most went unused.
    ///
    /// **A change here does not reach an existing install.** `seedIfNeeded`
    /// writes only files that are missing, which is what makes hand-edited
    /// prompts safe — so an edited seed only appears on a machine that has
    /// never had that file. A *new* seed does appear everywhere, because its
    /// file is missing by definition.
    static let seeds: [SummaryTemplate] = [
        SummaryTemplate(
            id: "general",
            name: "General",
            prompt: """
                You are summarising a meeting transcript for the person who attended it.

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
                - If the transcript is too garbled or too short to summarise, say so plainly
                  instead of producing a plausible-sounding summary.
                - Prefer the attendee's own notes where they conflict with the transcript;
                  they were there and the transcript may have misheard.
                - Write in British English.
                """),
        SummaryTemplate(
            id: "one-to-one",
            name: "1:1",
            prompt: """
                You are summarising a one-to-one conversation for one of the two people in it.

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
                - Say plainly if the transcript is too thin to summarise.
                - Write in British English.
                """),
        SummaryTemplate(
            id: "standup",
            name: "Stand-up",
            prompt: """
                You are summarising a status meeting.

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
                - Write in British English.
                """),
        SummaryTemplate(
            id: "hiring",
            name: "Hiring",
            prompt: """
                You are summarising a job interview for the interviewer who conducted it.

                This summary is about a real person and may feed a decision that affects
                them, so being accurate matters more than being complete or readable.

                Write in Markdown, omitting any section with no content:

                ## Summary
                Two to four sentences: the role, and what ground the interview covered.

                ## Your call
                If the interviewer's notes contain a verdict, a rating, a score or a
                leaning, reproduce it here in their own words, first, and unchanged. It is
                the most important line in the document and the one they will look for
                first months later. Omit this section entirely if they didn't record one —
                never fill it in on their behalf.

                ## What they claimed
                Their account of their experience, attributed to them rather than stated
                as fact — "said they led…", not "led…".

                ## Evidence given
                Specific examples they offered, with what *they* personally did as
                distinct from what their team or company did. Note where an example was
                asked for and not given.

                ## Strengths
                Only those an example in the transcript actually supports. Cite it.

                ## Concerns
                Same standard: the observation, and what prompted it. No inferences about
                the person beyond what was said.

                ## Questions they asked
                What the candidate wanted to know — often the most revealing part, and the
                easiest to forget.

                ## Still to establish
                What a next conversation would need to cover, as questions.

                ## Practicalities
                Notice period, availability, location, compensation — only if stated.

                Rules:
                - Only use what is in the transcript and notes. Never invent an example,
                  a name, a number, a date or a qualification.
                - Keep "claimed" and "demonstrated" apart everywhere. An interview is
                  mostly the former, and a summary that blurs them misleads a decision.
                - **Never infer or mention age, gender, ethnicity, nationality, accent,
                  religion, health, disability, family or any other protected or personal
                  characteristic**, even if it is audible in the recording or mentioned in
                  passing. It is irrelevant to the role and unlawful to weigh.
                - **Reach no verdict of your own** — no score, rating, ranking or
                  hire/no-hire recommendation that the interviewer did not write. Your job
                  is to hand the evidence back accurately, not to anchor them.
                  This is *not* a rule against recording *their* judgement: if their notes
                  contain a rating or a recommendation, it goes in "Your call" verbatim,
                  never softened, sharpened, hedged or argued with. Suppressing their own
                  conclusion would be the worse failure.
                - Prefer the interviewer's own notes where they conflict with the
                  transcript; they were there and the transcript may have misheard.
                - Say plainly if the transcript is too thin to summarise.
                - Write in British English.
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

    /// Cached listing, invalidated by the templates' own modification dates.
    ///
    /// Same shape as `Config.current()`, and for the same reason — but keyed on
    /// the *files*, not the directory. A directory's mtime changes only when an
    /// entry is added or removed, so an in-place edit of an existing prompt
    /// would never invalidate a directory-keyed cache, and this type's whole
    /// premise is that editing a template is opening the file.
    ///
    /// Worth caching because `all()` is a computed property on three view models
    /// and is read from inside `MeetingDetailView.body` — which re-evaluates on
    /// every keystroke in the notes editor. Uncached that was a directory
    /// listing plus four reads and parses per character, on the main thread.
    private struct Cache: Sendable {
        var templates: [SummaryTemplate]?
        var fingerprint: [String: Date]?
    }
    private static let cache = OSAllocatedUnfairLock(initialState: Cache())

    /// Names and modification dates in one directory read. Nil when the folder
    /// isn't readable, which simply means "don't cache" — `all()` still answers.
    private static func fingerprint() -> [String: Date]? {
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        var out: [String: Date] = [:]
        for url in urls where url.pathExtension == "md" {
            out[url.lastPathComponent] =
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }
        return out
    }

    /// Every template in the folder, sorted by display name.
    static func all() -> [SummaryTemplate] {
        if let current = fingerprint(),
            let hit = cache.withLock({ $0.fingerprint == current ? $0.templates : nil })
        {
            return hit
        }

        let parsed = load()
        // Fingerprint *after* seeding: `load()` may write missing seed files,
        // and storing the pre-seed fingerprint would miss on every call.
        cache.withLock { $0 = Cache(templates: parsed, fingerprint: fingerprint()) }
        return parsed
    }

    private static func load() -> [SummaryTemplate] {
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
