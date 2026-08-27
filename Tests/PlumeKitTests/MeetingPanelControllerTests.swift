import Foundation
import Testing

@testable import PlumeKit

@Suite("Meeting panel")
struct MeetingPanelControllerTests {
    @Test("ordinary live notes are persisted by the Stop flush")
    @MainActor
    func liveNotesSurviveStopFlush() throws {
        let session = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: session) }

        let controller = MeetingPanelController()
        controller.session = session
        controller.isRecording = true
        controller.notes = "Pricing objection\nFollow up with Lea exactly as written."

        controller.flushNotes()

        #expect(NotesStore.read(from: session) == controller.notes)
    }
}
