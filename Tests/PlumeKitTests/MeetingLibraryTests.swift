import Foundation
import Testing

@testable import PlumeKit

@Suite("Meeting library")
struct MeetingLibraryTests {

    /// Build a session folder the way the pipeline would.
    private func makeSession(
        in root: URL, name: String, title: String, started: String,
        duration: Int, stage: SessionState.Stage,
        blocker: SessionState.Blocker? = nil,
        summary: String = "*pending*"
    ) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: SessionState.directory(in: url), withIntermediateDirectories: true)
        try SessionState(stage: stage, blocker: blocker).save(to: url)
        try MeetingDocument.write(
            MeetingDocument.render(
                frontmatter: [
                    ("plume", "1"), ("title", title),
                    ("started", started), ("duration_s", "\(duration)"),
                ],
                notes: "", summary: summary,
                transcript: "**[0:00] me:** hello\n\n**[0:04] S1:** hi"),
            to: url.appendingPathComponent("meeting.md"))
        return url
    }

    private func tempRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("meetings are listed newest first")
    func newestFirst() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try makeSession(
            in: root, name: "2026-08-10-0900", title: "Older",
            started: "2026-08-10T09:00:00+02:00", duration: 600, stage: .summarized)
        _ = try makeSession(
            in: root, name: "2026-08-14-1400", title: "Newer",
            started: "2026-08-14T14:00:00+02:00", duration: 1800, stage: .summarized)

        let entries = MeetingLibrary.entries(in: root)
        #expect(entries.map(\.title) == ["Newer", "Older"])
    }

    @Test("frontmatter supplies the title, date and duration")
    func readsFrontmatter() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeSession(
            in: root, name: "2026-08-14-1400", title: "Pricing review",
            started: "2026-08-14T14:00:00+02:00", duration: 1800, stage: .summarized)

        let entry = try #require(MeetingLibrary.entries(in: root).first)
        #expect(entry.title == "Pricing review")
        #expect(entry.started != nil)
        #expect(entry.durationSeconds == 1800)
        #expect(entry.subtitle.contains("30 min"))
    }

    @Test("a transcribed meeting with no summary is flagged, not treated as broken")
    func awaitingSummaryIsNormal() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeSession(
            in: root, name: "2026-08-14-1400", title: "Unsummarized",
            started: "2026-08-14T14:00:00+02:00", duration: 60, stage: .transcribed)

        let entry = try #require(MeetingLibrary.entries(in: root).first)
        // Closing the laptop after a call is normal; summarizing is human-triggered.
        #expect(entry.awaitingSummary)
        #expect(!entry.hasSummary)
        #expect(entry.blocker == nil)
    }

    @Test("a blocked meeting is not counted as merely awaiting a summary")
    func blockedIsDistinct() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try makeSession(
            in: root, name: "2026-08-14-1400", title: "Failed",
            started: "2026-08-14T14:00:00+02:00", duration: 60, stage: .transcribed,
            blocker: .failed(stage: .transcribed, message: "ollama down"))

        let entry = try #require(MeetingLibrary.entries(in: root).first)
        #expect(!entry.awaitingSummary)
        #expect(entry.blocker != nil)
    }

    @Test("folders without pipeline state are ignored")
    func ignoresForeignFolders() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A stray folder, or one predating the stage machine — not ours to list.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("random-folder"),
            withIntermediateDirectories: true)
        _ = try makeSession(
            in: root, name: "2026-08-14-1400", title: "Real",
            started: "2026-08-14T14:00:00+02:00", duration: 60, stage: .summarized)

        #expect(MeetingLibrary.entries(in: root).map(\.title) == ["Real"])
    }

    @Test("a missing or unreadable meeting.md falls back to the folder name")
    func fallsBackToFolderName() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("2026-08-14-1400", isDirectory: true)
        try FileManager.default.createDirectory(
            at: SessionState.directory(in: url), withIntermediateDirectories: true)
        try SessionState(stage: .recorded).save(to: url)

        // Recorded but not yet transcribed: state exists, meeting.md does not.
        let entry = try #require(MeetingLibrary.entries(in: root).first)
        #expect(entry.title == "2026-08-14-1400")
        #expect(entry.stage == .recorded)
    }

    @Test("an empty root lists nothing rather than failing")
    func emptyRoot() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(MeetingLibrary.entries(in: root).isEmpty)
    }
}

@Suite("Markdown blocks")
struct MarkdownBlockTests {
    @Test("the subset our templates emit parses into blocks")
    func templateOutput() {
        // Verbatim shape of a General-template summary.
        let blocks = MarkdownBlock.parse("""
            ## Summary
            We agreed to ship on Friday.

            ## Actions
            - [ ] Marie — send the pricing deck
            - [x] Tom — booked the room
            """)
        #expect(blocks == [
            .heading(level: 2, text: "Summary"),
            .paragraph("We agreed to ship on Friday."),
            .heading(level: 2, text: "Actions"),
            .task(done: false, text: "Marie — send the pricing deck"),
            .task(done: true, text: "Tom — booked the room"),
        ])
    }

    @Test("task items are not mistaken for plain bullets")
    func tasksBeforeBullets() {
        // "- [ ] x" matches both patterns; the task reading must win.
        #expect(MarkdownBlock.parse("- [ ] do it") == [.task(done: false, text: "do it")])
        #expect(MarkdownBlock.parse("- just a bullet") == [.bullet("just a bullet")])
    }

    @Test("wrapped prose joins into one paragraph, blank lines separate")
    func paragraphWrapping() {
        #expect(MarkdownBlock.parse("one line\nstill the same\n\nnew one") == [
            .paragraph("one line still the same"),
            .paragraph("new one"),
        ])
    }

    @Test("unrecognised markdown degrades to a paragraph rather than vanishing")
    func unknownSyntaxSurvives() {
        // A template could emit anything; nothing may be silently dropped.
        let blocks = MarkdownBlock.parse("| a | table |")
        #expect(blocks == [.paragraph("| a | table |")])
    }

    @Test("empty input produces no blocks")
    func empty() {
        #expect(MarkdownBlock.parse("   \n\n  ").isEmpty)
    }
}
