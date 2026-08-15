import Foundation
import Testing

@testable import PlumeKit

@Suite("Speaker editing")
struct SpeakerEditingTests {

    private let transcript = """
        **[0:00] me:** morning
        **[0:04] S1:** hello, S1 here is my badge number
        **[0:09] S2:** and I'm the other one
        **[0:14] S1:** back to me
        """

    @Test("labels are listed in first-appearance order with samples")
    func listing() {
        let speakers = SpeakerEditing.speakers(in: transcript)
        #expect(speakers.map(\.label) == ["me", "S1", "S2"])
        #expect(speakers[1].samples.first == "hello, S1 here is my badge number")
    }

    @Test("renaming only touches the speaker field, never the spoken text")
    func renameIsAnchored() throws {
        // The line "hello, S1 here…" contains S1 inside the *text*. A naive
        // find-and-replace would corrupt it, and with the audio deleted there
        // would be nothing to check against.
        let renamed = try SpeakerEditing.rename("S1", to: "Marie", in: transcript)
        #expect(renamed.contains("**[0:04] Marie:** hello, S1 here is my badge number"))
        #expect(renamed.contains("**[0:14] Marie:** back to me"))
        #expect(renamed.contains("**[0:09] S2:**"))
    }

    @Test("renaming onto an existing label is refused, not silently merged")
    func renameOntoExistingRefused() {
        // Fusing two people by typo is unrecoverable; merging is a deliberate act.
        #expect(throws: SpeakerEditing.EditError.self) {
            try SpeakerEditing.rename("S1", to: "S2", in: transcript)
        }
    }

    @Test("renaming an unknown label fails rather than doing nothing")
    func unknownLabelThrows() {
        #expect(throws: SpeakerEditing.EditError.self) {
            try SpeakerEditing.rename("S9", to: "Ghost", in: transcript)
        }
    }

    @Test("merging folds one label into another")
    func merging() throws {
        // Diarization's characteristic failure: one person split across two
        // labels. Rename alone cannot repair it.
        let merged = try SpeakerEditing.merge("S2", into: "S1", in: transcript)
        let labels = SpeakerEditing.speakers(in: merged).map(\.label)
        #expect(labels == ["me", "S1"])
        #expect(merged.contains("**[0:09] S1:** and I'm the other one"))
    }

    @Test("merge is order-preserving and lossless")
    func mergeKeepsEveryLine() throws {
        let merged = try SpeakerEditing.merge("S2", into: "S1", in: transcript)
        #expect(merged.components(separatedBy: "\n").count
            == transcript.components(separatedBy: "\n").count)
        #expect(merged.contains("and I'm the other one"))
        #expect(merged.contains("back to me"))
    }

    @Test("non-transcript lines pass through untouched")
    func proseSurvives() throws {
        let withProse = transcript + "\n\n> a note I typed by hand about S1\n"
        let renamed = try SpeakerEditing.rename("S1", to: "Marie", in: withProse)
        #expect(renamed.contains("> a note I typed by hand about S1"))
    }

    @Test("timestamps survive an edit")
    func stampsSurvive() throws {
        let renamed = try SpeakerEditing.rename("S1", to: "Marie", in: transcript)
        for stamp in ["0:00", "0:04", "0:09", "0:14"] {
            #expect(renamed.contains("**[\(stamp)]"))
        }
    }

    @Test("renaming and merging round-trip through meeting.md")
    func documentLevel() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("meeting.md")

        try MeetingDocument.write(
            MeetingDocument.render(
                frontmatter: [("plume", "1"), ("speaker_S1", "S1")],
                notes: "my notes", summary: "a summary", transcript: transcript),
            to: url)

        try SpeakerEditing.apply(to: url) {
            try SpeakerEditing.rename("S1", to: "Marie", in: $0)
        } frontmatter: { pairs in
            if let i = pairs.firstIndex(where: { $0.0 == "speaker_S1" }) {
                pairs[i] = ("speaker_S1", "Marie")
            }
        }

        let updated = try String(contentsOf: url, encoding: .utf8)
        #expect(try MeetingDocument.read(.transcript, from: updated).contains("Marie:**"))
        // Everything else must be untouched — invariant 1.
        #expect(try MeetingDocument.read(.notes, from: updated) == "my notes")
        #expect(try MeetingDocument.read(.summary, from: updated) == "a summary")
        #expect(MeetingDocument.frontmatter(in: updated)
            .first(where: { $0.0 == "speaker_S1" })?.1 == "Marie")
    }
}

@Suite("Notes store")
struct NotesStoreTests {
    private func tempSession() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("notes taken during the call are stamped with elapsed time")
    func stampedDuringCall() {
        #expect(NotesStore.trimmedLine("check pricing", elapsed: 124) == "- [2:04] check pricing")
        #expect(NotesStore.trimmedLine("later", elapsed: 3725) == "- [1:02:05] later")
    }

    @Test("notes added after the call carry no timestamp")
    func unstampedAfterCall() {
        #expect(NotesStore.trimmedLine("final thought", elapsed: nil) == "- final thought")
    }

    @Test("blank input is ignored rather than writing an empty bullet")
    func blankIgnored() {
        #expect(NotesStore.trimmedLine("   \n ", elapsed: 10).isEmpty)
    }

    @Test("appending is crash-safe and accumulates in order")
    func appending() throws {
        let session = tempSession()
        defer { try? FileManager.default.removeItem(at: session) }

        try NotesStore.append("first", elapsed: 5, to: session)
        try NotesStore.append("second", elapsed: 65, to: session)

        let contents = NotesStore.read(from: session)
        #expect(contents == "- [0:05] first\n- [1:05] second\n")
    }

    @Test("the wrap-up marker is written once and only after real notes")
    func wrapUpMarker() throws {
        let session = tempSession()
        defer { try? FileManager.default.removeItem(at: session) }

        // Nothing typed yet — no point marking a boundary in an empty file.
        try NotesStore.markWrapUp(in: session)
        #expect(NotesStore.read(from: session).isEmpty)

        try NotesStore.append("during", elapsed: 5, to: session)
        try NotesStore.markWrapUp(in: session)
        try NotesStore.markWrapUp(in: session)

        let occurrences = NotesStore.read(from: session)
            .components(separatedBy: NotesStore.wrapUpMarker).count - 1
        #expect(occurrences == 1)
    }

    @Test("wrap-up editing replaces the whole file")
    func wholeFileEditing() throws {
        let session = tempSession()
        defer { try? FileManager.default.removeItem(at: session) }

        try NotesStore.append("typo hree", elapsed: 5, to: session)
        // "Add last thoughts before summarising" implies tidying, not only appending.
        try NotesStore.write("- [0:05] typo here\n- cleaned up\n", to: session)
        #expect(NotesStore.read(from: session) == "- [0:05] typo here\n- cleaned up\n")
    }
}
