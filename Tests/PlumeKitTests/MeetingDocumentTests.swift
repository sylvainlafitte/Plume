import Foundation
import Testing

@testable import PlumeKit

@Suite("Meeting document")
struct MeetingDocumentTests {

    private func sample() -> String {
        MeetingDocument.render(
            frontmatter: [("plume", "1"), ("title", "Weekly sync")],
            notes: "- ship the thing",
            summary: "*pending*",
            transcript: "**[00:12] Me:** hello")
    }

    // MARK: - Round-trip

    @Test("a rendered document reads back region by region")
    func roundTrip() throws {
        let doc = sample()
        #expect(try MeetingDocument.read(.notes, from: doc) == "- ship the thing")
        #expect(try MeetingDocument.read(.summary, from: doc) == "*pending*")
        #expect(try MeetingDocument.read(.transcript, from: doc) == "**[00:12] Me:** hello")
    }

    @Test("frontmatter round-trips as ordered flat pairs")
    func frontmatterRoundTrip() {
        let pairs = MeetingDocument.frontmatter(in: sample())
        #expect(pairs.map(\.0) == ["plume", "title"])
        #expect(pairs.map(\.1) == ["1", "Weekly sync"])
    }

    @Test("values containing a colon survive quoting")
    func frontmatterQuoting() {
        let rendered = MeetingDocument.renderFrontmatter([
            ("started", "2026-08-14T14:02:11+02:00"),
            ("title", "Re: pricing"),
        ])
        let parsed = MeetingDocument.frontmatter(in: rendered + "\nbody")
        #expect(parsed.first(where: { $0.0 == "started" })?.1 == "2026-08-14T14:02:11+02:00")
        #expect(parsed.first(where: { $0.0 == "title" })?.1 == "Re: pricing")
    }

    // MARK: - Invariant 1

    @Test("replacing one region leaves the others byte-identical")
    func replacementIsSurgical() throws {
        let doc = sample()
        let updated = try MeetingDocument.replacing(
            .summary, with: "Decided to ship on Friday.", in: doc)

        #expect(try MeetingDocument.read(.summary, from: updated) == "Decided to ship on Friday.")
        // The regions we did not touch must be untouched.
        #expect(try MeetingDocument.read(.notes, from: updated)
            == (try MeetingDocument.read(.notes, from: doc)))
        #expect(try MeetingDocument.read(.transcript, from: updated)
            == (try MeetingDocument.read(.transcript, from: doc)))
        #expect(MeetingDocument.frontmatter(in: updated).map(\.1)
            == MeetingDocument.frontmatter(in: doc).map(\.1))
    }

    @Test("a missing marker fails loudly instead of appending a duplicate")
    func missingMarkerThrows() throws {
        // The exact damage invariant 1 exists to prevent: a user deletes the
        // markers, and a naive writer appends a second summary while the first
        // silently stays.
        var mangled = sample()
        mangled = mangled.replacingOccurrences(
            of: MeetingDocument.Region.summary.end, with: "")

        #expect(throws: MeetingDocument.DocumentError.self) {
            try MeetingDocument.replacing(.summary, with: "new", in: mangled)
        }
        #expect(throws: MeetingDocument.DocumentError.self) {
            try MeetingDocument.read(.summary, from: mangled)
        }
    }

    @Test("markers in the wrong order are rejected")
    func outOfOrderMarkersThrow() {
        let broken = """
            \(MeetingDocument.Region.notes.end)
            body
            \(MeetingDocument.Region.notes.begin)
            """
        #expect(throws: MeetingDocument.DocumentError.self) {
            try MeetingDocument.replacing(.notes, with: "x", in: broken)
        }
    }

    @Test("hand-edited content outside the replaced region survives")
    func handEditsSurvive() throws {
        var doc = sample()
        // Simulate the user editing in Obsidian: extra prose after the transcript.
        doc += "\n\n> a note I added by hand\n"
        let updated = try MeetingDocument.replacing(.summary, with: "regenerated", in: doc)
        #expect(updated.contains("> a note I added by hand"))
    }

    @Test("a user's own edits inside Notes are preserved when Summary regenerates")
    func notesPreservedAcrossRegeneration() throws {
        var doc = sample()
        doc = try MeetingDocument.replacing(
            .notes, with: "- my own words\n- second line", in: doc)
        let regenerated = try MeetingDocument.replacing(.summary, with: "v2", in: doc)
        #expect(try MeetingDocument.read(.notes, from: regenerated)
            == "- my own words\n- second line")
    }

    @Test("replacing is idempotent — repeated writes don't accumulate")
    func idempotentReplacement() throws {
        var doc = sample()
        for _ in 0..<5 {
            doc = try MeetingDocument.replacing(.summary, with: "same text", in: doc)
        }
        // One heading, one marker pair, one body — no duplication.
        #expect(doc.components(separatedBy: "## Summary").count - 1 == 1)
        #expect(doc.components(separatedBy: MeetingDocument.Region.summary.begin).count - 1 == 1)
        #expect(try MeetingDocument.read(.summary, from: doc) == "same text")
    }

    @Test("an empty body leaves the region present but blank")
    func emptyBody() throws {
        let doc = try MeetingDocument.replacing(.notes, with: "", in: sample())
        #expect(try MeetingDocument.read(.notes, from: doc) == "")
        // The markers must survive, or the next write would fail loudly.
        #expect(doc.contains(MeetingDocument.Region.notes.begin))
        #expect(doc.contains(MeetingDocument.Region.notes.end))
    }

    // MARK: - Disk

    @Test("writing preserves extended attributes on the existing file")
    func writePreservesXattrs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("meeting.md")

        try MeetingDocument.write(sample(), to: url)
        // Finder tags and similar live in xattrs; Data.write(.atomic) drops them
        // by swapping the inode, which is why we use replaceItemAt.
        let value = Data("tagged".utf8)
        try value.withUnsafeBytes { buffer in
            let result = setxattr(
                url.path, "com.plume.test", buffer.baseAddress, buffer.count, 0, 0)
            #expect(result == 0)
        }

        try MeetingDocument.updateRegion(.summary, at: url, to: "rewritten")

        let size = getxattr(url.path, "com.plume.test", nil, 0, 0, 0)
        #expect(size == 6, "extended attribute lost — replaceItemAt not used?")
        let reread = try String(contentsOf: url, encoding: .utf8)
        #expect(try MeetingDocument.read(.summary, from: reread) == "rewritten")
    }

    @Test("updateRegion re-reads from disk, so external edits are not clobbered")
    func updateRereadsFromDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("meeting.md")
        try MeetingDocument.write(sample(), to: url)

        // Someone edits Notes in another editor while Plume holds an old copy.
        let external = try MeetingDocument.replacing(
            .notes, with: "edited elsewhere",
            in: try String(contentsOf: url, encoding: .utf8))
        try external.write(to: url, atomically: true, encoding: .utf8)

        try MeetingDocument.updateRegion(.summary, at: url, to: "generated")

        let final = try String(contentsOf: url, encoding: .utf8)
        #expect(try MeetingDocument.read(.notes, from: final) == "edited elsewhere")
        #expect(try MeetingDocument.read(.summary, from: final) == "generated")
    }
}

@Suite("Region heading de-duplication")
struct RegionHeadingTests {
    @Test("a model repeating the region's heading doesn't double it")
    func stripsRepeatedHeading() throws {
        // Templates tell the model to write "## Summary" as its first section,
        // which collided with the region's own heading in the first real run.
        let doc = MeetingDocument.render(
            frontmatter: [], notes: "", summary: "*pending*", transcript: "x")
        let updated = try MeetingDocument.replacing(
            .summary, with: "## Summary\n\nIt went well.", in: doc)
        #expect(updated.components(separatedBy: "## Summary").count - 1 == 1)
        #expect(try MeetingDocument.read(.summary, from: updated) == "It went well.")
    }

    @Test("a heading that is part of a sentence is left alone")
    func keepsGenuineHeadings() {
        // "## Summary of costs" is a real section title, not a duplicate.
        #expect(MeetingDocument.stripLeadingHeading(.summary, from: "## Summary of costs\n\nx")
            == "## Summary of costs\n\nx")
        // Later sections must survive untouched.
        let body = "It went well.\n\n## Decisions\n\n- ship it"
        #expect(MeetingDocument.stripLeadingHeading(.summary, from: body) == body)
    }
}

@Suite("Document format versioning")
struct DocumentFormatTests {

    private func tempDocument(plume: String?) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).md")
        var pairs: [(String, String)] = []
        if let plume { pairs.append((MeetingDocument.versionKey, plume)) }
        pairs.append(("title", "a meeting"))
        try MeetingDocument.render(
            frontmatter: pairs, notes: "mine", summary: "*pending*", transcript: "x"
        ).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("a document written by this build declares the current format")
    func stampsCurrentVersion() {
        let doc = MeetingDocument.render(
            frontmatter: [(MeetingDocument.versionKey, "\(MeetingDocument.formatVersion)")],
            transcript: "x")
        #expect(MeetingDocument.declaredFormat(in: doc) == MeetingDocument.formatVersion)
    }

    @Test("a document with no plume key is treated as current, not as broken")
    func missingKeyIsTolerated() throws {
        // A hand-edited file that lost its frontmatter must stay editable —
        // the same tolerance SessionState.machine gets.
        let url = try tempDocument(plume: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(MeetingDocument.declaredFormat(in: "") == nil)
        try MeetingDocument.updateRegion(.notes, at: url, to: "still writable")
        #expect(try MeetingDocument.read(.notes, from:
            String(contentsOf: url, encoding: .utf8)) == "still writable")
    }

    @Test("a document from a newer Plume is refused, not rewritten")
    func futureDocumentIsRefused() throws {
        // The audio is already gone (invariant 6), so a bad rewrite of a format
        // we don't understand cannot be regenerated from anything.
        let url = try tempDocument(plume: "\(MeetingDocument.formatVersion + 1)")
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try String(contentsOf: url, encoding: .utf8)

        #expect(throws: MeetingDocument.DocumentError.self) {
            try MeetingDocument.updateRegion(.notes, at: url, to: "clobbered")
        }
        #expect(throws: MeetingDocument.DocumentError.self) {
            try MeetingDocument.updateFrontmatter(at: url) { pairs in
                MeetingDocument.setValue("new", for: "title", in: &pairs)
            }
        }
        #expect(throws: MeetingDocument.DocumentError.self) {
            try SpeakerEditing.apply(to: url) { _ in "clobbered" }
        }
        // The file is byte-identical: refusing must not half-write.
        #expect(try String(contentsOf: url, encoding: .utf8) == before)
    }

    @Test("an older document is still writable — tolerance runs one way only")
    func olderDocumentIsWritable() throws {
        let url = try tempDocument(plume: "0")
        defer { try? FileManager.default.removeItem(at: url) }
        try MeetingDocument.updateRegion(.notes, at: url, to: "fine")
        #expect(try MeetingDocument.read(.notes, from:
            String(contentsOf: url, encoding: .utf8)) == "fine")
    }
}
