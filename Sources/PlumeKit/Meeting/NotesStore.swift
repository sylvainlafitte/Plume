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
enum NotesStore {

    static func url(in session: URL) -> URL {
        SessionState.directory(in: session).appendingPathComponent("notes.md")
    }

    /// Separates in-the-moment capture from wrap-up, so the summarizer can read
    /// what follows as conclusions.
    ///
    /// Blank lines on both sides and an explicit rule: without them it rendered
    /// flush against the preceding note and read as part of it.
    static let wrapUpMarker = "*— after the call —*"

    static func read(from session: URL) -> String {
        (try? String(contentsOf: url(in: session), encoding: .utf8)) ?? ""
    }

    static func write(_ contents: String, to session: URL) throws {
        let url = url(in: session)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Append the wrap-up divider, separated by blank lines. No-op if the notes
    /// are empty (nothing to divide) or it is already there.
    static func markWrapUp(in session: URL) throws -> String {
        let existing = read(from: session)
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(wrapUpMarker) else { return existing }

        let updated = trimmed + "\n\n" + wrapUpMarker + "\n\n"
        try write(updated, to: session)
        return updated
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
