import Testing

@testable import PlumeKit

@Suite("Notes autosave")
struct NotesAutosaveTests {
    @Test("flush only writes when a save is pending")
    @MainActor
    func pendingOnly() {
        var saves = 0
        let autosave = NotesAutosave(interval: 60) { saves += 1 }

        autosave.flush()
        #expect(saves == 0)

        autosave.schedule()
        autosave.flush()
        autosave.flush()
        #expect(saves == 1)
    }
}
