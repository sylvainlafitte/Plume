import Foundation

/// Renaming and merging speakers inside `meeting.md`.
///
/// Both rewrite the transcript region, so both are anchored to the line-leading
/// `**[m:ss] label:** ` form. A naive find-and-replace of `S1` would also hit
/// "S1" occurring inside what someone said — which is exactly the kind of quiet
/// corruption that is only noticed much later, with no audio left to check
/// against (invariant 5).
enum SpeakerEditing {

    enum EditError: Error, CustomStringConvertible, Equatable {
        case unknownLabel(String)
        case nameAlreadyUsed(String)

        var description: String {
            switch self {
            case .unknownLabel(let label): return "no speaker labelled \(label)"
            case .nameAlreadyUsed(let name):
                return "\(name) is already in use — merge the speakers instead of renaming onto it"
            }
        }
    }

    /// Labels in first-appearance order, with a few representative lines each.
    static func speakers(in transcript: String, samplesPerSpeaker: Int = 3)
        -> [(label: String, samples: [String])]
    {
        var order: [String] = []
        var samples: [String: [String]] = [:]
        for line in transcript.components(separatedBy: "\n") {
            guard let parsed = parse(line) else { continue }
            if !order.contains(parsed.label) { order.append(parsed.label) }
            if samples[parsed.label, default: []].count < samplesPerSpeaker {
                samples[parsed.label, default: []].append(parsed.text)
            }
        }
        return order.map { ($0, samples[$0] ?? []) }
    }

    /// Rename one label. Refuses to rename onto a label that already exists —
    /// that is a *merge*, and doing it by typo would silently fuse two people.
    static func rename(_ label: String, to name: String, in transcript: String) throws -> String {
        let existing = speakers(in: transcript).map(\.label)
        guard existing.contains(label) else { throw EditError.unknownLabel(label) }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !existing.contains(where: { $0 == trimmed && $0 != label }) else {
            throw EditError.nameAlreadyUsed(trimmed)
        }
        return rewrite(transcript) { $0 == label ? trimmed : $0 }
    }

    /// Fold `source` into `destination`. The repair for diarization's most
    /// common error: one person split across two labels.
    static func merge(_ source: String, into destination: String, in transcript: String)
        throws -> String
    {
        let existing = speakers(in: transcript).map(\.label)
        guard existing.contains(source) else { throw EditError.unknownLabel(source) }
        guard existing.contains(destination) else { throw EditError.unknownLabel(destination) }
        return rewrite(transcript) { $0 == source ? destination : $0 }
    }

    // MARK: - Line handling

    /// `**[12:04] S1:** text` → (label, text). Anything else is left alone, so
    /// hand-written prose inside the region survives untouched.
    static func parse(_ line: String) -> (stamp: String, label: String, text: String)? {
        guard line.hasPrefix("**["), let closeBracket = line.firstIndex(of: "]") else {
            return nil
        }
        let stamp = String(line[line.index(line.startIndex, offsetBy: 3)..<closeBracket])
        let rest = line[line.index(after: closeBracket)...]
        guard let marker = rest.range(of: ":** ") else { return nil }
        let label = rest[rest.startIndex..<marker.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return (stamp, label, String(rest[marker.upperBound...]))
    }

    private static func rewrite(_ transcript: String, mapping: (String) -> String) -> String {
        transcript.components(separatedBy: "\n").map { line -> String in
            guard let parsed = parse(line) else { return line }
            return "**[\(parsed.stamp)] \(mapping(parsed.label)):** \(parsed.text)"
        }.joined(separator: "\n")
    }

    // MARK: - Document level

    /// Apply an edit to `meeting.md`, updating the frontmatter speaker map too.
    static func apply(
        to meetingURL: URL, _ edit: (String) throws -> String,
        frontmatter: ((inout [(String, String)]) -> Void)? = nil
    ) throws {
        let document = try String(contentsOf: meetingURL, encoding: .utf8)
        let transcript = try MeetingDocument.read(
            .transcript, from: document, path: meetingURL.lastPathComponent)
        var updated = try MeetingDocument.replacing(
            .transcript, with: try edit(transcript), in: document,
            path: meetingURL.lastPathComponent)

        if let frontmatter {
            var pairs = MeetingDocument.frontmatter(in: updated)
            frontmatter(&pairs)
            if let end = updated.range(of: "\n---\n") {
                updated = MeetingDocument.renderFrontmatter(pairs)
                    + String(updated[end.upperBound...])
            }
        }
        try MeetingDocument.write(updated, to: meetingURL)
    }
}
