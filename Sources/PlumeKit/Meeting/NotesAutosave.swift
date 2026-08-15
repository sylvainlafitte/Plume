import Foundation

/// Debounced whole-file notes save, shared by both surfaces.
///
/// Notes are free text, so every keystroke would otherwise rewrite the file;
/// 1.2 s keeps that to a trickle while risking at most a second or two of typing
/// on a crash — the cost accepted when automatic timestamps were dropped and
/// notes became one plain document.
///
/// Both surfaces had their own copy of this timer. **`flush()` must run before a
/// surface switches meetings**, or pending text lands in the wrong one: starting
/// a second recording while the first is still in wrap-up is a designed-for case
/// (PLAN R11), not an edge one.
@MainActor
final class NotesAutosave {
    private var timer: Timer?
    private let interval: TimeInterval
    private let save: () -> Void

    init(interval: TimeInterval = 1.2, save: @escaping () -> Void) {
        self.interval = interval
        self.save = save
    }

    func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    func flush() {
        timer?.invalidate()
        timer = nil
        save()
    }
}
