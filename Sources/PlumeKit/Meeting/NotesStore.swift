import Foundation

/// Notes typed during and after a meeting, at `.plume/notes.md`.
///
/// Free text, saved whole. An earlier design stamped every line with elapsed
/// time automatically; that was dropped because the stamps went stale the moment
/// a line was reworded, and most notes are general observations that a precise
/// timestamp misrepresents. A timestamp is now something you *insert
/// deliberately* (⌘T) when a thought really is anchored to a moment.
///
/// The trade-off: whole-file saves are marginally less crash-safe than the
/// previous append-only journal. Writes are debounced by the caller, so a crash
/// costs at most the last second or two of typing — acceptable for a notes field
/// that no longer fights you when you edit it.
///
/// There is deliberately no during/after-the-call divider. It existed when every
/// line carried an automatic timestamp and the boundary was therefore visible
/// structure; with free-text notes it was structure leaking into the user's own
/// words for no benefit the model actually needed.
enum NotesStore {

    static func url(in session: URL) -> URL {
        SessionState.directory(in: session).appendingPathComponent("notes.md")
    }

    static func read(from session: URL) -> String {
        (try? String(contentsOf: url(in: session), encoding: .utf8)) ?? ""
    }

    static func write(_ contents: String, to session: URL) throws {
        let url = url(in: session)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// `[12:04] ` — inserted on request, never automatically.
    static func stamp(_ elapsed: TimeInterval) -> String {
        "[\(clock(elapsed))] "
    }

    /// Text with a timestamp started on a fresh line, ready to type after.
    static func appendingStamp(to text: String, elapsed: TimeInterval) -> String {
        let base = text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
        return base + stamp(elapsed)
    }

    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
