import Foundation

/// One past meeting, as the history list needs to show it.
struct MeetingEntry: Identifiable, Equatable, Sendable {
    var id: URL { url }
    let url: URL
    let title: String
    let started: Date?
    let durationSeconds: Int?
    let stage: SessionState.Stage
    let blocker: SessionState.Blocker?
    let hasSummary: Bool

    /// Transcribed but never summarized. Normal, not an error — summarizing is
    /// human-triggered — but worth surfacing so a meeting doesn't quietly rot.
    var awaitingSummary: Bool { stage == .transcribed && blocker == nil }

    var subtitle: String {
        var parts: [String] = []
        if let started {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            parts.append(formatter.string(from: started))
        }
        if let durationSeconds, durationSeconds > 0 {
            parts.append(durationSeconds < 60
                ? "\(durationSeconds)s"
                : "\(durationSeconds / 60) min")
        }
        return parts.joined(separator: " · ")
    }
}

/// Reads the meetings folder into a list.
///
/// The folder *is* the database — there is no index to keep in sync, which is
/// the whole point of one markdown file per meeting. Scanning reads only each
/// file's frontmatter block, so a folder of long transcripts stays cheap.
enum MeetingLibrary {

    static func entries(in root: URL) -> [MeetingEntry] {
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }

        return directories
            .compactMap(entry(at:))
            // Newest first: the meeting you want is almost always the last one.
            .sorted { ($0.started ?? .distantPast) > ($1.started ?? .distantPast) }
    }

    static func entry(at url: URL) -> MeetingEntry? {
        // A session without state is not ours — a stray folder, or one from
        // before the stage machine existed.
        guard let state = SessionState.load(from: url) else { return nil }

        let meeting = url.appendingPathComponent("meeting.md")
        let frontmatter = readFrontmatter(at: meeting)
        let values = Dictionary(frontmatter, uniquingKeysWith: { first, _ in first })

        return MeetingEntry(
            url: url,
            title: values["title"].flatMap { $0.isEmpty ? nil : $0 }
                ?? url.lastPathComponent,
            started: values["started"].flatMap(parseDate),
            durationSeconds: values["duration_s"].flatMap(Int.init),
            stage: state.stage,
            blocker: state.blocker,
            hasSummary: state.stage == .summarized
        )
    }

    /// Read just the frontmatter block. Stops at the closing `---`, so a
    /// two-hour transcript is never loaded to render a list row.
    private static func readFrontmatter(at url: URL) -> [(String, String)] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        // Frontmatter is a handful of short lines; 4 KB is generous.
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        return MeetingDocument.frontmatter(in: String(decoding: head, as: UTF8.self))
    }

    private static func parseDate(_ value: String) -> Date? {
        let withOffset = ISO8601DateFormatter()
        withOffset.formatOptions = [.withInternetDateTime]
        if let date = withOffset.date(from: value) { return date }
        // Older sessions were written in UTC with fractional seconds.
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fallback.date(from: value)
    }
}
