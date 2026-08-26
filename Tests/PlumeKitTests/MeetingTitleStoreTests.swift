import Foundation
import Testing

@testable import PlumeKit

@Suite("Meeting titles")
struct MeetingTitleStoreTests {

    private func makeSession(document: Bool = true) throws -> URL {
        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let work = SessionState.directory(in: session)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let metadata: [String: Any] = [
            "started": "2026-08-14T14:00:00+02:00",
            "files": ["mic": "mic.caf"],
            "future_key": ["keep": true],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: work.appendingPathComponent("meta.json"), options: .atomic)
        if document {
            try MeetingDocument.write(
                MeetingDocument.render(
                    frontmatter: [("plume", "1")],
                    notes: "mine", summary: "*pending*", transcript: "hello"),
                to: session.appendingPathComponent("meeting.md"))
        }
        return session
    }

    @Test("normalization flattens pasted lines without changing internal spaces")
    func normalization() {
        #expect(MeetingTitleStore.normalize("  Pricing  review \n  next steps  ")
            == "Pricing  review next steps")
        #expect(MeetingTitleStore.normalize("\n \r\n") == nil)
    }

    @Test("human title persists without moving and preserves unknown metadata")
    func humanTitleIsSurgical() throws {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session) }

        let title = try MeetingTitleStore.setUserTitle(" Pricing\nreview ", in: session)

        #expect(title == "Pricing review")
        #expect(session.lastPathComponent != "pricing-review")
        let metadataData = try Data(
            contentsOf: SessionState.directory(in: session).appendingPathComponent("meta.json"))
        let metadata = try #require(
            JSONSerialization.jsonObject(with: metadataData) as? [String: Any])
        #expect(metadata[MeetingTitleStore.metadataKey] as? String == "Pricing review")
        #expect((metadata["future_key"] as? [String: Bool])?["keep"] == true)

        let document = try String(
            contentsOf: session.appendingPathComponent("meeting.md"), encoding: .utf8)
        let pairs = MeetingDocument.frontmatter(in: document)
        #expect(pairs.first { $0.0 == "title" }?.1 == "Pricing review")
        #expect(pairs.first { $0.0 == "title_source" }?.1 == "user")
        #expect(try MeetingDocument.read(.notes, from: document) == "mine")
    }

    @Test("metadata title is available before meeting.md exists")
    func titleBeforeTranscript() throws {
        let session = try makeSession(document: false)
        defer { try? FileManager.default.removeItem(at: session) }
        try MeetingTitleStore.setUserTitle("Early title", in: session)
        #expect(MeetingTitleStore.title(in: session) == "Early title")
    }

    @Test("reconciliation makes the latest metadata title win")
    func reconciliationWins() throws {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session) }
        try MeetingTitleStore.setUserTitle("Human title", in: session)
        try MeetingDocument.updateFrontmatter(
            at: session.appendingPathComponent("meeting.md")
        ) { pairs in
            MeetingDocument.setValue("Derived title", for: "title", in: &pairs)
        }

        try MeetingTitleStore.reconcileUserTitle(in: session)

        #expect(MeetingTitleStore.title(in: session) == "Human title")
        #expect(MeetingAdmin.isUserTitled(session: session))
    }

    @Test("legacy timestamp titles are untitled")
    func legacyTimestampIsUntitled() {
        #expect(MeetingTitleStore.title(
            frontmatter: [("title", "2026-08-14-1400")],
            metadataTitle: nil,
            folderName: "2026-08-14-1400") == nil)
        #expect(MeetingTitleStore.title(
            frontmatter: [("title", "Pricing review")],
            metadataTitle: nil,
            folderName: "2026-08-14-1400-pricing-review") == "Pricing review")
    }

    @Test("future document formats refuse a title without changing metadata")
    func futureDocumentIsRefused() throws {
        let session = try makeSession()
        defer { try? FileManager.default.removeItem(at: session) }
        try MeetingDocument.updateFrontmatter(
            at: session.appendingPathComponent("meeting.md")
        ) { pairs in
            MeetingDocument.setValue(
                "\(MeetingDocument.formatVersion + 1)",
                for: MeetingDocument.versionKey,
                in: &pairs)
        }

        #expect(throws: MeetingDocument.DocumentError.self) {
            try MeetingTitleStore.setUserTitle("Future title", in: session)
        }
        #expect(try MeetingTitleStore.userTitle(in: session) == nil)
    }

    @Test("summary finalization reconciles a human title before moving")
    func summaryFinalization() throws {
        let session = try makeSession()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stamped = root.appendingPathComponent("2026-08-14-1400", isDirectory: true)
        try FileManager.default.moveItem(at: session, to: stamped)
        try MeetingTitleStore.setUserTitle("Human title", in: stamped)

        let final = try MeetingSummaryFinalizer.finalize(session: stamped)

        #expect(final.lastPathComponent == "2026-08-14-1400-human-title")
        #expect(MeetingTitleStore.title(in: final) == "Human title")
    }

    @Test("missing legacy metadata cannot turn a written summary into a failure")
    func summaryFinalizationWithoutMetadata() throws {
        let session = try makeSession()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stamped = root.appendingPathComponent("2026-08-14-1400", isDirectory: true)
        try FileManager.default.moveItem(at: session, to: stamped)
        try FileManager.default.removeItem(
            at: SessionState.directory(in: stamped).appendingPathComponent("meta.json"))
        try MeetingDocument.updateFrontmatter(
            at: stamped.appendingPathComponent("meeting.md")
        ) { pairs in
            MeetingDocument.setValue("Derived title", for: "title", in: &pairs)
        }

        let final = try MeetingSummaryFinalizer.finalize(session: stamped)

        #expect(final.lastPathComponent == "2026-08-14-1400-derived-title")
    }
}
