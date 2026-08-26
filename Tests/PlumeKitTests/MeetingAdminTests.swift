import Foundation
import Testing

@testable import PlumeKit

@Suite("Meeting folder admin")
struct MeetingAdminTests {

    private func makeSession(named name: String, title: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: SessionState.directory(in: url), withIntermediateDirectories: true)
        try SessionState(stage: .summarized).save(to: url)
        try MeetingDocument.write(
            MeetingDocument.render(
                frontmatter: [("plume", "1"), ("title", title)],
                notes: "- mine", summary: "a summary", transcript: "**[0:00] me:** hi"),
            to: url.appendingPathComponent("meeting.md"))
        return url
    }

    @Test("summary-boundary rename preserves the timestamp and document")
    func renameFolder() throws {
        let session = try makeSession(named: "2026-08-14-1400-old-name", title: "Pricing review")
        defer { try? FileManager.default.removeItem(at: session.deletingLastPathComponent()) }

        let renamed = MeetingAdmin.renameFolder(session, toSlugOf: "Pricing review")

        #expect(renamed.lastPathComponent == "2026-08-14-1400-pricing-review")
        let document = try String(
            contentsOf: renamed.appendingPathComponent("meeting.md"), encoding: .utf8)
        #expect(try MeetingDocument.read(.notes, from: document) == "- mine")
        #expect(try MeetingDocument.read(.summary, from: document) == "a summary")
        #expect(try MeetingDocument.read(.transcript, from: document) == "**[0:00] me:** hi")
    }

    @Test("a colliding folder name is disambiguated, never merged into")
    func collisionIsDisambiguated() throws {
        let session = try makeSession(named: "2026-08-14-1400-a", title: "Standup")
        let parent = session.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent.appendingPathComponent("2026-08-14-1400-standup"),
            withIntermediateDirectories: true)

        let renamed = MeetingAdmin.renameFolder(session, toSlugOf: "Standup")
        #expect(renamed.lastPathComponent == "2026-08-14-1400-standup-2")
        #expect(FileManager.default.fileExists(
            atPath: parent.appendingPathComponent("2026-08-14-1400-standup").path))
    }

    @Test("a title with no slug-able characters keeps the folder name")
    func unsluggableTitleKeepsFolder() throws {
        let session = try makeSession(named: "2026-08-14-1400-x", title: "???")
        defer { try? FileManager.default.removeItem(at: session.deletingLastPathComponent()) }
        #expect(MeetingAdmin.renameFolder(session, toSlugOf: "???") == session)
    }

    @Test("folder slugs respect the UTF-8 byte budget")
    func unicodeSlugBudget() {
        let slug = MeetingIdentityDeriver.slug(String(repeating: "é", count: 300))
        #expect(slug.utf8.count <= 229)
        #expect(String(data: Data(slug.utf8), encoding: .utf8) == slug)
    }

    @Test("Trash receives and moves the complete session folder")
    func trashMovesWholeSession() throws {
        let session = try makeSession(named: "2026-08-14-1400-x", title: "X")
        let root = session.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let destination = trash.appendingPathComponent(session.lastPathComponent, isDirectory: true)

        try MeetingAdmin.trash(session: session) {
            try FileManager.default.moveItem(at: $0, to: destination)
        }

        #expect(!FileManager.default.fileExists(atPath: session.path))
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("meeting.md").path))
        #expect(FileManager.default.fileExists(
            atPath: SessionState.url(in: destination).path))
    }

    @Test("setting a frontmatter key that isn't there appends it")
    func setValueAppends() {
        var pairs = [("plume", "1"), ("title", "X")]
        MeetingDocument.setValue("user", for: "title_source", in: &pairs)
        MeetingDocument.setValue("Y", for: "title", in: &pairs)
        #expect(pairs.map(\.0) == ["plume", "title", "title_source"])
        #expect(pairs.first { $0.0 == "title" }?.1 == "Y")
    }
}
