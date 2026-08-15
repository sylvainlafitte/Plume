import Foundation
import Testing

@testable import PlumeKit

/// Loading rules both surfaces used to open-code, now testable without a window.
@Suite("Meeting content")
struct MeetingContentTests {

    private func tempSession() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let transcript = """
        **[0:00] me:** morning
        **[0:02] S1:** morning — shall we start?
        **[0:07] S2:** give me a second
        """

    @Test("the *pending* placeholder is not shown as a summary")
    func pendingIsNotASummary() {
        // Transcription writes `*pending*` so meeting.md is complete before any
        // model runs. Rendering it verbatim would tell the user the model had
        // produced something. Both surfaces normalised this separately.
        let document = MeetingDocument.render(
            frontmatter: [], summary: "*pending*", transcript: "")
        #expect(MeetingContent.summaryBody(from: document).isEmpty)

        let real = MeetingDocument.render(
            frontmatter: [], summary: "## Decisions\nship it", transcript: "")
        #expect(MeetingContent.summaryBody(from: real).contains("ship it"))
    }

    @Test("a document with no summary region reads as empty, not as a failure")
    func missingRegionIsEmpty() {
        #expect(MeetingContent.summaryBody(from: "no markers here").isEmpty)
    }

    @Test("speaker rows cover the remote speakers only")
    func speakerRowsSkipMe() {
        let session = tempSession()
        defer { try? FileManager.default.removeItem(at: session) }

        let rows = MeetingContent.speakerRows(session: session, transcript: transcript)
        // "me" is you by construction and has nothing to rename.
        #expect(rows.map(\.label) == ["S1", "S2"])
        #expect(rows.allSatisfy { !$0.samples.isEmpty })
        // No proposals file yet, so nothing is offered.
        #expect(rows.allSatisfy { $0.proposal == nil })
    }

    @Test("derived names arrive as proposals, never applied")
    func proposalsStayProposals() throws {
        let session = tempSession()
        defer { try? FileManager.default.removeItem(at: session) }
        try FileManager.default.createDirectory(
            at: SessionState.directory(in: session), withIntermediateDirectories: true)
        try MeetingIdentity(
            title: "Planning",
            speakers: [
                SpeakerProposal(
                    label: "S1", name: "Marie", confidence: 0.9,
                    evidence: "introduced themselves")
            ]
        ).save(to: session)

        let rows = MeetingContent.speakerRows(session: session, transcript: transcript)
        // Invariant 3: the row is still labelled S1 and carries the name as an
        // offer awaiting one human click.
        #expect(rows.first?.label == "S1")
        #expect(rows.first?.proposal?.name == "Marie")
    }

    @Test("a meeting with no document yet loads as nil, which is a resting state")
    func untranscribedLoadsAsNil() {
        let session = tempSession()
        defer { try? FileManager.default.removeItem(at: session) }
        // Recorded but not yet transcribed: normal, not an error.
        #expect(MeetingContent.load(session: session) == nil)
    }

    @Test("loading a finished meeting yields summary and speakers together")
    func loadsBoth() throws {
        let session = tempSession()
        defer { try? FileManager.default.removeItem(at: session) }
        try MeetingDocument.write(
            MeetingDocument.render(
                frontmatter: [("plume", "1")],
                notes: "mine", summary: "the summary", transcript: transcript),
            to: session.appendingPathComponent("meeting.md"))

        let loaded = try #require(MeetingContent.load(session: session))
        #expect(loaded.summary == "the summary")
        #expect(loaded.speakerRows.map(\.label) == ["S1", "S2"])
    }
}
