import Foundation

/// Notes typed during and just after a meeting, at `.plume/notes.md`.
///
/// Two different write modes, on purpose:
///
/// **During the call** notes are *appended*, one line per entry, each stamped
/// with elapsed time. Appending is crash-safe and costs nothing per keystroke —
/// and critically, it does not touch `meeting.md`, which does not exist yet.
/// Writing into the meeting file live would mean re-reading and rewriting it
/// constantly, and would race with anything the user has open in an editor.
///
/// **During wrap-up** the whole file is editable: "add last thoughts before
/// summarising" implies tidying what is already there, not only appending.
enum NotesStore {

    static func url(in session: URL) -> URL {
        SessionState.directory(in: session).appendingPathComponent("notes.md")
    }

    /// Marks the boundary between in-the-moment capture and wrap-up. The
    /// summarizer can weight what follows as conclusions rather than notes
    /// taken mid-sentence.
    static let wrapUpMarker = "--- after the call ---"

    /// Append one stamped line. `elapsed` is nil once the recording has stopped.
    static func append(_ text: String, elapsed: TimeInterval?, to session: URL) throws {
        let line = trimmedLine(text, elapsed: elapsed)
        guard !line.isEmpty else { return }

        let url = url(in: session)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
        try (existing + separator + line + "\n").write(
            to: url, atomically: true, encoding: .utf8)
    }

    /// Record that the call has ended, so later notes are distinguishable.
    static func markWrapUp(in session: URL) throws {
        let existing = read(from: session)
        guard !existing.contains(wrapUpMarker) else { return }
        guard !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try append(wrapUpMarker, elapsed: nil, to: session)
    }

    static func read(from session: URL) -> String {
        (try? String(contentsOf: url(in: session), encoding: .utf8)) ?? ""
    }

    /// Replace the whole file — the wrap-up editor's save path.
    static func write(_ contents: String, to session: URL) throws {
        let url = url(in: session)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// `- [12:04] text`, or `- text` after the call. Timestamps let the model
    /// line a note up against the transcript around it.
    static func trimmedLine(_ text: String, elapsed: TimeInterval?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // The wrap-up marker is structure, not a note.
        guard trimmed != wrapUpMarker else { return trimmed }
        guard let elapsed else { return "- \(trimmed)" }
        return "- [\(clock(elapsed))] \(trimmed)"
    }

    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
