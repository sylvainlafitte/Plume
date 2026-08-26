import Foundation

/// Human meeting titles, kept separate from folder moves.
///
/// The helper is synchronous and stateless. App call sites invoke it on
/// `MainActor`, while the bundle-less summarize command calls it from its
/// detached task — that command blocks the main thread while it runs.
enum MeetingTitleStore {
    static let metadataKey = "user_title"

    enum TitleError: Error, CustomStringConvertible {
        case unreadableMetadata(URL)

        var description: String {
            switch self {
            case .unreadableMetadata(let url):
                return "can't parse \(url.path)"
            }
        }
    }

    static func normalize(_ raw: String) -> String? {
        let title = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    static func userTitle(in session: URL) throws -> String? {
        let metadata = try readMetadata(in: session)
        return (metadata[metadataKey] as? String).flatMap(normalize)
    }

    /// Persist a human title, updating the document too once it exists.
    ///
    /// Metadata is written first: if transcription is between its initial title
    /// read and document creation, its final reconciliation still sees this value.
    @discardableResult
    static func setUserTitle(_ raw: String, in session: URL) throws -> String? {
        guard let title = normalize(raw) else { return nil }

        let meetingURL = session.appendingPathComponent("meeting.md")
        if FileManager.default.fileExists(atPath: meetingURL.path) {
            let document = try String(contentsOf: meetingURL, encoding: .utf8)
            try MeetingDocument.checkWritable(document, path: meetingURL.lastPathComponent)
        }

        var metadata = try readMetadata(in: session)
        metadata[metadataKey] = title
        try writeMetadata(metadata, in: session)

        if FileManager.default.fileExists(atPath: meetingURL.path) {
            try applyHumanTitle(title, at: meetingURL)
        }
        return title
    }

    /// Re-apply the durable metadata title after transcription or identity
    /// derivation. A legacy user-titled document without `user_title` is left
    /// untouched.
    @discardableResult
    static func reconcileUserTitle(in session: URL) throws -> String? {
        guard let title = try userTitle(in: session) else { return nil }
        let meetingURL = session.appendingPathComponent("meeting.md")
        guard FileManager.default.fileExists(atPath: meetingURL.path) else { return title }
        try applyHumanTitle(title, at: meetingURL)
        return title
    }

    /// The actual title, never a timestamp-folder fallback.
    ///
    /// Metadata wins because it is the durable record of a human edit. Documents
    /// from before `user_title` still use `title_source: user`.
    static func title(in session: URL) -> String? {
        let metadataTitle = try? userTitle(in: session)
        let meetingURL = session.appendingPathComponent("meeting.md")
        let frontmatter = (try? String(contentsOf: meetingURL, encoding: .utf8))
            .map(MeetingDocument.frontmatter(in:)) ?? []
        return title(
            frontmatter: frontmatter,
            metadataTitle: metadataTitle ?? nil,
            folderName: session.lastPathComponent)
    }

    static func title(
        frontmatter: [(String, String)],
        metadataTitle: String?,
        folderName: String
    ) -> String? {
        if let metadataTitle = metadataTitle.flatMap(normalize) {
            return metadataTitle
        }

        let title = (frontmatter.first { $0.0 == "title" }?.1).flatMap(normalize)
        guard let title else { return nil }
        let source = frontmatter.first { $0.0 == MeetingAdmin.titleSourceKey }?.1
        if source == nil, title == folderName {
            return nil
        }
        return title
    }

    private static func applyHumanTitle(_ title: String, at meetingURL: URL) throws {
        try MeetingDocument.updateFrontmatter(at: meetingURL) { pairs in
            MeetingDocument.setValue(title, for: "title", in: &pairs)
            MeetingDocument.setValue("user", for: MeetingAdmin.titleSourceKey, in: &pairs)
        }
    }

    private static func metadataURL(in session: URL) -> URL {
        SessionState.directory(in: session).appendingPathComponent("meta.json")
    }

    private static func readMetadata(in session: URL) throws -> [String: Any] {
        let url = metadataURL(in: session)
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw TitleError.unreadableMetadata(url) }
        return object
    }

    private static func writeMetadata(_ metadata: [String: Any], in session: URL) throws {
        let data = try JSONSerialization.data(
            withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: metadataURL(in: session), options: .atomic)
    }
}
