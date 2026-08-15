import Foundation

/// Renaming and deleting a meeting — the two operations that change what a
/// session *is* rather than what it says.
///
/// Both are riskier than they look. Renaming collides with auto-titling, which
/// re-derives a title on every summarize; deleting removes the only surviving
/// copy of a meeting, because the audio was deleted the moment the transcript
/// was written (invariant 6).
enum MeetingAdmin {

    /// Frontmatter key marking a title as chosen by a person.
    ///
    /// Invariant 3 applied to titles: a derived name is a proposal, a typed one
    /// is a fact, and the pipeline must not overwrite a fact. Without this the
    /// next Regenerate would silently restore the model's title — the edit
    /// would appear to work and then quietly undo itself, which is worse than
    /// not offering rename at all.
    static let titleSourceKey = "title_source"

    static func isUserTitled(_ document: String) -> Bool {
        MeetingDocument.frontmatter(in: document)
            .first { $0.0 == titleSourceKey }?.1 == "user"
    }

    static func isUserTitled(session: URL) -> Bool {
        guard let document = try? String(
            contentsOf: session.appendingPathComponent("meeting.md"), encoding: .utf8)
        else { return false }
        return isUserTitled(document)
    }

    /// Give a meeting a human-chosen title, and move the folder to match.
    ///
    /// Returns the session URL, which changes when the folder is renamed.
    /// The `yyyy-MM-dd-HHmm` prefix is preserved: the list sorts on it, and
    /// several places locate a renamed session by matching that prefix.
    @discardableResult
    static func rename(session: URL, to title: String) throws -> URL {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AdminError.emptyTitle }

        try MeetingDocument.updateFrontmatter(
            at: session.appendingPathComponent("meeting.md")
        ) { pairs in
            MeetingDocument.setValue(trimmed, for: "title", in: &pairs)
            MeetingDocument.setValue("user", for: titleSourceKey, in: &pairs)
        }

        return renameFolder(session, toSlugOf: trimmed)
    }

    /// Move the folder to `<stamp>-<slug>`, disambiguating a collision rather
    /// than merging into an existing meeting or failing outright.
    ///
    /// A failed move is cosmetic — the title in the file is what the UI shows —
    /// so this never throws; the worst case is a folder whose name lags the
    /// title, which is exactly what happens today when auto-titling can't move
    /// the folder either.
    static func renameFolder(_ session: URL, toSlugOf title: String) -> URL {
        let slug = MeetingIdentityDeriver.slug(title)
        guard !slug.isEmpty else { return session }
        let stamp = session.lastPathComponent.prefix(15)  // yyyy-MM-dd-HHmm
        let parent = session.deletingLastPathComponent()

        var candidate = parent.appendingPathComponent("\(stamp)-\(slug)", isDirectory: true)
        var suffix = 2
        while candidate != session, FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent(
                "\(stamp)-\(slug)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        guard candidate != session else { return session }

        do {
            try FileManager.default.moveItem(at: session, to: candidate)
            return candidate
        } catch {
            return session
        }
    }

    /// Move a meeting to the Trash.
    ///
    /// **Never `removeItem`.** The audio is already gone by the time a meeting
    /// is listed, so `meeting.md` is the only copy of something that cannot be
    /// reproduced from anything else — a mis-click has to stay recoverable.
    static func trash(session: URL) throws {
        try FileManager.default.trashItem(at: session, resultingItemURL: nil)
    }

    enum AdminError: Error, CustomStringConvertible, Equatable {
        case emptyTitle

        var description: String {
            switch self {
            case .emptyTitle: return "a meeting needs a title"
            }
        }
    }
}
