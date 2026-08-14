import Foundation
import Testing

@testable import PlumeKit

@Suite("AppState")
@MainActor
struct AppStateTests {
    @Test("elapsed text is derived from the start date, not accumulated")
    func elapsedDerived() {
        let state = AppState()
        #expect(state.elapsedText == nil)
        state.recording = .recording(since: Date().addingTimeInterval(-125))
        #expect(state.elapsedText == "2:05")
    }

    @Test("elapsed text switches to h:mm:ss past an hour")
    func elapsedHours() {
        let state = AppState()
        state.recording = .recording(since: Date().addingTimeInterval(-3725))
        #expect(state.elapsedText == "1:02:05")
    }

    @Test("failures are sticky until explicitly cleared")
    func failuresStick() {
        let state = AppState()
        #expect(state.lastFailure == nil)
        state.report("diarizer model missing")
        #expect(state.lastFailure?.message == "diarizer model missing")

        // A later unrelated state change must not clear it — the whole point is
        // that a menubar app has no console for errors to scroll past in.
        state.transcription = .working(name: "meeting", queued: 0)
        #expect(state.lastFailure != nil)

        state.clearFailure()
        #expect(state.lastFailure == nil)
    }

    @Test("a newer failure supersedes an older one")
    func failureSupersedes() {
        let state = AppState()
        state.report("first")
        state.report("second")
        #expect(state.lastFailure?.message == "second")
    }

    @Test("isRecording reflects the case, not a separate flag")
    func recordingFlag() {
        let state = AppState()
        #expect(!state.recording.isRecording)
        state.recording = .recording(since: Date())
        #expect(state.recording.isRecording)
    }
}
