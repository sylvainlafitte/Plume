import Foundation
import Testing

@testable import PlumeKit

@Suite("Recording session metadata")
struct RecordingSessionTests {
    @Test("Stop publishes atomic metadata before recorded state")
    @MainActor
    func stopWritesTitleAndState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try RecordingSession(root: root)
        session.userTitle = "  Planning\nnext steps "
        session.expectedParticipants = 3
        try session.stop()

        #expect(try MeetingTitleStore.userTitle(in: session.dir) == "Planning next steps")
        #expect(SessionState.load(from: session.dir)?.stage == .recorded)
        let metadata = try JSONSerialization.jsonObject(
            with: Data(contentsOf: session.workDir.appendingPathComponent("meta.json")))
            as? [String: Any]
        #expect(metadata?["expected_participants"] as? Int == 3)
    }
}
