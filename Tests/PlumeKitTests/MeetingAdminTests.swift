import Foundation
import Testing

@testable import PlumeKit

@Suite("Meeting rename and delete")
struct MeetingAdminTests {

    /// A session folder with a meeting.md, as the pipeline leaves it.
    private func makeSession(named name: String, title: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try MeetingDocument.write(
            MeetingDocument.render(
                frontmatter: [("plume", "1"), ("title", title)],
                notes: "- mine", summary: "a summary", transcript: "**[0:00] me:** hi"),
            to: url.appendingPathComponent("meeting.md"))
        return url
    }

    @Test("renaming sets the title, marks it human, and moves the folder")
    func renameMovesFolder() throws {
        let session = try makeSession(named: "2026-08-14-1400-old-name", title: "Old name")
        defer { try? FileManager.default.removeItem(at: session.deletingLastPathComponent()) }

        let renamed = try MeetingAdmin.rename(session: session, to: "Pricing review")

        // The timestamp prefix is load-bearing: the list sorts on it and
        // renamed sessions are located by matching it.
        #expect(renamed.lastPathComponent == "2026-08-14-1400-pricing-review")
        let document = try String(
            contentsOf: renamed.appendingPathComponent("meeting.md"), encoding: .utf8)
        #expect(MeetingDocument.frontmatter(in: document)
            .first { $0.0 == "title" }?.1 == "Pricing review")
        #expect(MeetingAdmin.isUserTitled(document))
    }

    @Test("renaming leaves every region untouched")
    func renameIsSurgical() throws {
        let session = try makeSession(named: "2026-08-14-1400-x", title: "X")
        defer { try? FileManager.default.removeItem(at: session.deletingLastPathComponent()) }

        let renamed = try MeetingAdmin.rename(session: session, to: "Y")
        let document = try String(
            contentsOf: renamed.appendingPathComponent("meeting.md"), encoding: .utf8)
        #expect(try MeetingDocument.read(.notes, from: document) == "- mine")
        #expect(try MeetingDocument.read(.summary, from: document) == "a summary")
        #expect(try MeetingDocument.read(.transcript, from: document) == "**[0:00] me:** hi")
    }

    @Test("an auto-derived title never overwrites one a person typed")
    func userTitleWins() throws {
        // The whole point of the marker: without it the next Regenerate would
        // silently undo the rename.
        let session = try makeSession(named: "2026-08-14-1400-x", title: "X")
        defer { try? FileManager.default.removeItem(at: session.deletingLastPathComponent()) }

        let renamed = try MeetingAdmin.rename(session: session, to: "Mine")
        #expect(MeetingAdmin.isUserTitled(session: renamed))

        // A meeting that was never renamed stays fair game for auto-titling.
        let fresh = try makeSession(named: "2026-08-14-1500-y", title: "Y")
        defer { try? FileManager.default.removeItem(at: fresh.deletingLastPathComponent()) }
        #expect(!MeetingAdmin.isUserTitled(session: fresh))
    }

    @Test("a colliding folder name is disambiguated, never merged into")
    func collisionIsDisambiguated() throws {
        let session = try makeSession(named: "2026-08-14-1400-a", title: "A")
        let parent = session.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: parent) }
        // Another meeting from the same minute that already owns the slug.
        try FileManager.default.createDirectory(
            at: parent.appendingPathComponent("2026-08-14-1400-standup"),
            withIntermediateDirectories: true)

        let renamed = try MeetingAdmin.rename(session: session, to: "Standup")
        #expect(renamed.lastPathComponent == "2026-08-14-1400-standup-2")
        // The squatter is untouched.
        #expect(FileManager.default.fileExists(
            atPath: parent.appendingPathComponent("2026-08-14-1400-standup").path))
    }

    @Test("an empty title is refused rather than blanking the meeting")
    func emptyTitleRefused() throws {
        let session = try makeSession(named: "2026-08-14-1400-x", title: "X")
        defer { try? FileManager.default.removeItem(at: session.deletingLastPathComponent()) }
        #expect(throws: MeetingAdmin.AdminError.emptyTitle) {
            try MeetingAdmin.rename(session: session, to: "   ")
        }
    }

    @Test("a title with no slug-able characters keeps the folder name")
    func unsluggableTitleKeepsFolder() throws {
        let session = try makeSession(named: "2026-08-14-1400-x", title: "X")
        defer { try? FileManager.default.removeItem(at: session.deletingLastPathComponent()) }

        let renamed = try MeetingAdmin.rename(session: session, to: "???")
        #expect(renamed == session)
        // The title still lands, even though the folder can't carry it.
        let document = try String(
            contentsOf: renamed.appendingPathComponent("meeting.md"), encoding: .utf8)
        #expect(MeetingDocument.frontmatter(in: document).first { $0.0 == "title" }?.1 == "???")
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
