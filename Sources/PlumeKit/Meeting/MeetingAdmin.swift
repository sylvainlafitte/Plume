import Foundation

/// Moving and deleting a meeting — the two operations that change where the
/// complete session folder lives.
///
/// Both are riskier than they look. A move invalidates every model holding the
/// old URL; deleting removes the only surviving copy of a meeting, because the
/// audio was deleted the moment the transcript was written (invariant 6).
enum MeetingAdmin {

    /// Frontmatter key marking a title as chosen by a person.
    ///
    /// Invariant 3 applied to titles: a derived name is a proposal, a typed one
    /// is a fact, and the pipeline must not overwrite a fact. Without this the
    /// next Regenerate would silently restore the model's title — the edit
    /// would appear to work and then quietly undo itself, which is worse than
    /// not offering title editing at all.
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
    static func trash(
        session: URL,
        using operation: (URL) throws -> Void = {
            try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
        }
    ) throws {
        try operation(session)
    }
}
