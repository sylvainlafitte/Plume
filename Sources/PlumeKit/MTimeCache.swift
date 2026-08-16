import Foundation
import os.lock

/// A value cached against a filesystem fingerprint, recomputed when it changes.
///
/// Three stores had grown their own copy of this — `Config`, `TemplateStore`,
/// `VocabularyStore` — each with a private `Cache` struct, its own lock, and the
/// same check-compute-store dance. They exist for one shared reason: every one
/// of these files is meant to be **hand-edited**, so a stale read is
/// indistinguishable from the feature not working, while an uncached read is a
/// stat plus a parse on paths hot enough to matter (`TemplateStore.all()` is
/// read from inside `MeetingDetailView.body`, i.e. once per keystroke).
///
/// The fingerprint is whatever identifies "unchanged" for that store: one file's
/// modification date, or a whole directory's worth of them. It is deliberately
/// **not** the directory's own mtime, which only moves when an entry is added or
/// removed — a directory-keyed cache would ignore an in-place edit, and in-place
/// editing is the entire premise of the templates folder.
final class MTimeCache<Fingerprint: Equatable & Sendable, Value: Sendable>: Sendable {

    private struct Box: Sendable {
        var value: Value?
        var fingerprint: Fingerprint?
    }

    private let state = OSAllocatedUnfairLock(initialState: Box())

    /// Drop everything. Callers use this when the *path* changes underneath the
    /// cache — `Config.withPath`, `TemplateStore.withDirectory` — since two
    /// files' modification dates are not comparable, and a hit from one path
    /// would otherwise be served for the other.
    func invalidate() {
        state.withLock { $0 = Box() }
    }

    /// The cached value if `fingerprint()` is unchanged, otherwise `compute()`.
    ///
    /// A nil fingerprint means "unreadable — don't cache", not "empty": the
    /// value is still computed and returned, just never stored. `compute()` runs
    /// outside the lock (it does file I/O), and the fingerprint is re-read
    /// *after* it, because computing can itself create the files being
    /// fingerprinted — `TemplateStore` seeds missing templates on first read,
    /// and storing the pre-seed fingerprint would miss on every later call.
    func value(fingerprint: () -> Fingerprint?, compute: () -> Value) -> Value {
        if let current = fingerprint(),
            let hit = state.withLock({ $0.fingerprint == current ? $0.value : nil })
        {
            return hit
        }
        let computed = compute()
        // Re-read outside the lock, not inside it: `withLock`'s body is
        // `@Sendable` and cannot capture the caller's plain closure.
        let settled = fingerprint()
        state.withLock { $0 = Box(value: computed, fingerprint: settled) }
        return computed
    }
}
