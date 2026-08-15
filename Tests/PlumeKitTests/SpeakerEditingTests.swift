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

    @Test("timestamps are inserted on request, never automatically")
    func stampOnRequest() {
        // Auto-stamping every line was dropped: stamps went stale on edit, and
        // most notes are general observations a precise time misrepresents.
        #expect(NotesStore.stamp(124) == "[2:04] ")
        #expect(NotesStore.stamp(3725) == "[1:02:05] ")
    }

    @Test("inserting a stamp starts a fresh line, ready to type after")
    func stampStartsNewLine() {
        #expect(NotesStore.appendingStamp(to: "", elapsed: 65) == "[1:05] ")
        #expect(NotesStore.appendingStamp(to: "a thought", elapsed: 65)
            == "a thought\n[1:05] ")
        // Already at a line start — don't add a blank line.
        #expect(NotesStore.appendingStamp(to: "a thought\n", elapsed: 65)
            == "a thought\n[1:05] ")
    }

    @Test("the wrap-up divider is separated by blank lines")
    func wrapUpIsSeparated() throws {
        // It previously rendered flush against the last note and read as part
        // of it.
        let session = tempSession()
        defer { try? FileManager.default.removeItem(at: session) }

        try NotesStore.write("a thought", to: session)
        let updated = try NotesStore.markWrapUp(in: session)
        #expect(updated.contains("a thought\n\n" + NotesStore.wrapUpMarker))
    }

    @Test("the divider is written once, and never into empty notes")
    func wrapUpIdempotent() throws {
        let session = tempSession()
        defer { try? FileManager.default.removeItem(at: session) }

        // Nothing typed — no boundary worth marking.
        _ = try NotesStore.markWrapUp(in: session)
        #expect(NotesStore.read(from: session).isEmpty)

        try NotesStore.write("during", to: session)
        _ = try NotesStore.markWrapUp(in: session)
        _ = try NotesStore.markWrapUp(in: session)
        let occurrences = NotesStore.read(from: session)
            .components(separatedBy: NotesStore.wrapUpMarker).count - 1
        #expect(occurrences == 1)
    }

    @Test("notes round-trip as free text, unchanged")
    func freeTextRoundTrip() throws {
        let session = tempSession()
        defer { try? FileManager.default.removeItem(at: session) }
        // No bullets imposed, no reformatting — the user's text is the file.
        let text = "just prose\nand a second line\n\n[3:20] anchored to a moment\n"
        try NotesStore.write(text, to: session)
        #expect(NotesStore.read(from: session) == text)
    }
}
