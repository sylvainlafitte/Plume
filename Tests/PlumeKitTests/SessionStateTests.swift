import Foundation
import Testing

@testable import PlumeKit

@Suite("Session state")
struct SessionStateTests {

    private func tempSession() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("state survives a round trip through disk")
    func roundTrip() throws {
        let session = tempSession()
        defer { try? FileManager.default.removeItem(at: session) }

        try SessionState(stage: .transcribed).save(to: session)
        let loaded = SessionState.load(from: session)
        #expect(loaded?.stage == .transcribed)
        #expect(loaded?.blocker == nil)
    }

    @Test("a session with no state file reads as nil, not as an error")
    func missingStateIsNil() {
        #expect(SessionState.load(from: tempSession()) == nil)
    }

    @Test("transcribed-but-unsummarized is a normal resting state")
    func awaitingSummaryIsNormal() {
        // Closing the laptop after a call must not look like a failure: the
        // transcript is written and the summary is simply not requested yet.
        let state = SessionState(stage: .transcribed)
        #expect(state.isAwaitingSummary)
        #expect(state.isReadyForWork)
    }

    @Test("a failed stage is retried; permission and cancel are not")
    func blockerGovernsRetry() {
        let failed = SessionState(
            stage: .recorded, blocker: .failed(stage: .recorded, message: "model missing"))
        #expect(failed.isReadyForWork)
        #expect(failed.blocker?.isRetryable == true)

        // Retrying changes nothing until the user acts, so don't spin on it.
        let permission = SessionState(
            stage: .recorded, blocker: .needsPermission("microphone"))
        #expect(!permission.isReadyForWork)
        #expect(permission.blocker?.isRetryable == false)

        let cancelled = SessionState(stage: .transcribed, blocker: .cancelled)
        #expect(!cancelled.isReadyForWork)
    }

    @Test("a summarized session is finished regardless of blockers")
    func summarizedIsDone() {
        #expect(!SessionState(stage: .summarized).isReadyForWork)
        #expect(!SessionState(stage: .summarized).isAwaitingSummary)
    }

    @Test("advancing clears the blocker that was in the way")
    func advanceClearsBlocker() throws {
        let session = tempSession()
        defer { try? FileManager.default.removeItem(at: session) }

        try SessionState.block(session, with: .failed(stage: .recorded, message: "boom"))
        #expect(SessionState.load(from: session)?.blocker != nil)

        try SessionState.advance(session, to: .transcribed)
        let state = SessionState.load(from: session)
        #expect(state?.stage == .transcribed)
        #expect(state?.blocker == nil)
    }

    @Test("blocking preserves the stage already reached")
    func blockKeepsProgress() throws {
        let session = tempSession()
        defer { try? FileManager.default.removeItem(at: session) }

        try SessionState.advance(session, to: .transcribed)
        try SessionState.block(session, with: .failed(stage: .transcribed, message: "ollama down"))

        let state = SessionState.load(from: session)
        // Losing the stage here would re-transcribe a meeting whose audio is
        // already deleted — i.e. destroy it.
        #expect(state?.stage == .transcribed)
        #expect(state?.blocker == .failed(stage: .transcribed, message: "ollama down"))
    }

    @Test("stages are ordered so progress can be compared")
    func stageOrdering() {
        #expect(SessionState.Stage.recorded < .transcribed)
        #expect(SessionState.Stage.transcribed < .summarized)
    }

    @Test("state is written inside .plume, not beside meeting.md")
    func stateLivesInDotPlume() throws {
        let session = tempSession()
        defer { try? FileManager.default.removeItem(at: session) }
        try SessionState().save(to: session)

        #expect(FileManager.default.fileExists(
            atPath: session.appendingPathComponent(".plume/state.json").path))
        // The meeting folder itself stays clean — meeting.md is the only thing
        // the user should see in it.
        let visible = try FileManager.default.contentsOfDirectory(atPath: session.path)
            .filter { !$0.hasPrefix(".") }
        #expect(visible.isEmpty)
    }
}
