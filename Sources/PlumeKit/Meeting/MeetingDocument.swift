import Foundation

/// `meeting.md` — one file per meeting holding notes, summary and transcript.
///
/// Three regions with three different owners, delimited by HTML comments so each
/// is addressable. Regeneration replaces a region rather than rewriting the file,
/// which is what lets generated content live inside a file the user also edits.
///
/// Invariant 1: **never silently rewrite a marked region.** Re-read from disk
/// before every write, replace only between markers, and fail loudly if a marker
/// is missing — never append a duplicate section. A summary quietly appended
/// twice, or notes silently replaced, is the kind of damage that is only noticed
/// long after the audio is gone.
enum MeetingDocument {

    enum Region: String, CaseIterable {
        case notes, summary, transcript

        var begin: String { "<!-- plume:\(rawValue) start -->" }
        var end: String { "<!-- plume:\(rawValue) end -->" }
        var heading: String {
            switch self {
            case .notes: return "## Notes"
            case .summary: return "## Summary"
            case .transcript: return "## Transcript"
            }
        }
    }

    enum DocumentError: Error, CustomStringConvertible, Equatable {
        case missingMarker(region: String, marker: String, path: String)
        case markersOutOfOrder(region: String, path: String)

        var description: String {
            switch self {
            case .missingMarker(let region, let marker, let path):
                return """
                    \(path): missing \(marker) for the \(region) region. Refusing to write — \
                    appending would duplicate the section and hide the original.
                    """
            case .markersOutOfOrder(let region, let path):
                return "\(path): \(region) end marker precedes its start marker"
            }
        }
    }

    // MARK: - Rendering a fresh document

    /// Build a complete document. Notes and Summary come first because they are
    /// what you read; the transcript is reference material and is long.
    static func render(
        frontmatter: [(String, String)],
        notes: String = "",
        summary: String = "*pending*",
        transcript: String
    ) -> String {
        var out = renderFrontmatter(frontmatter)
        out += "\n"
        for region in Region.allCases {
            let body: String
            switch region {
            case .notes: body = notes
            case .summary: body = summary
            case .transcript: body = transcript
            }
            out += "\(region.begin)\n\(region.heading)\n\n"
            out += body.isEmpty ? "" : body.trimmingCharacters(in: .newlines) + "\n"
            out += "\(region.end)\n\n"
        }
        return out.trimmingCharacters(in: .newlines) + "\n"
    }

    /// Flat `key: value` only. No nested mappings: Obsidian's Properties system
    /// doesn't support them and rewrites the whole block when any property is
    /// edited, reordering and requoting as it goes. Flat means a five-line
    /// parser and no YAML dependency.
    static func renderFrontmatter(_ pairs: [(String, String)]) -> String {
        var out = "---\n"
        for (key, value) in pairs {
            out += "\(key): \(needsQuoting(value) ? "\"\(escaped(value))\"" : value)\n"
        }
        out += "---\n"
        return out
    }

    private static func needsQuoting(_ value: String) -> Bool {
        value.isEmpty || value.contains(":") || value.contains("#")
            || value.first == " " || value.last == " "
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Reading

    /// Parse the frontmatter block into ordered pairs. Returns empty when the
    /// document has none.
    static func frontmatter(in document: String) -> [(String, String)] {
        let lines = document.components(separatedBy: "\n")
        guard lines.first == "---" else { return [] }
        var pairs: [(String, String)] = []
        for line in lines.dropFirst() {
            if line == "---" { break }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<separator])
                .trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            guard !key.isEmpty else { continue }
            pairs.append((key, value))
        }
        return pairs
    }

    /// Contents of a region, excluding its markers and heading.
    static func read(_ region: Region, from document: String, path: String = "meeting.md")
        throws -> String
    {
        let (start, end) = try markerRange(region, in: document, path: path)
        var body = String(document[start..<end])
        if let headingRange = body.range(of: region.heading) {
            body = String(body[headingRange.upperBound...])
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Replacing

    /// Replace one region's body, leaving every other byte untouched.
    static func replacing(
        _ region: Region, with body: String, in document: String,
        path: String = "meeting.md"
    ) throws -> String {
        let (start, end) = try markerRange(region, in: document, path: path)
        let cleaned = stripLeadingHeading(region, from: body)
        let replacement =
            "\n\(region.heading)\n\n"
            + (cleaned.isEmpty ? "" : cleaned + "\n")
        return document.replacingCharacters(in: start..<end, with: replacement)
    }

    /// Drop a heading the body repeats, so the region's own heading isn't doubled.
    ///
    /// Summary templates instruct the model to emit `## Summary` as its first
    /// section — sensible in isolation, but the region already carries that
    /// heading, and the result was two in a row. Stripping here rather than
    /// forbidding it in the prompt keeps the templates readable standalone and
    /// tolerates a user writing their own.
    static func stripLeadingHeading(_ region: Region, from body: String) -> String {
        var trimmed = body.trimmingCharacters(in: .newlines)
        let heading = region.heading
        while true {
            let candidate = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidate.lowercased().hasPrefix(heading.lowercased()) else { break }
            let after = candidate.dropFirst(heading.count)
            // Only a heading on its own line, not "## Summary of costs".
            guard after.isEmpty || after.first == "\n" else { break }
            trimmed = String(after).trimmingCharacters(in: .newlines)
        }
        return trimmed
    }

    /// Range between a region's markers, exclusive of the markers themselves.
    private static func markerRange(
        _ region: Region, in document: String, path: String
    ) throws -> (String.Index, String.Index) {
        guard let begin = document.range(of: region.begin) else {
            throw DocumentError.missingMarker(
                region: region.rawValue, marker: region.begin, path: path)
        }
        guard let end = document.range(of: region.end) else {
            throw DocumentError.missingMarker(
                region: region.rawValue, marker: region.end, path: path)
        }
        guard begin.upperBound <= end.lowerBound else {
            throw DocumentError.markersOutOfOrder(region: region.rawValue, path: path)
        }
        return (begin.upperBound, end.lowerBound)
    }

    // MARK: - Disk

    /// Write via `FileManager.replaceItemAt`, not `Data.write(.atomic)`.
    ///
    /// Both are atomic, but `.atomic` swaps in a brand-new inode: extended
    /// attributes, Finder tags and file identity are lost, and anything holding
    /// the file open keeps the old one. `replaceItemAt` is the documented
    /// safe-save primitive and preserves them.
    static func write(_ contents: String, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        guard FileManager.default.fileExists(atPath: url.path) else {
            // Nothing to preserve yet; a plain atomic write is correct here and
            // avoids replaceItemAt's requirement that the original exist.
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        let temp = directory.appendingPathComponent(
            ".plume-write-\(UUID().uuidString).md")
        try contents.write(to: temp, atomically: false, encoding: .utf8)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Read the file, replace one region, write it back.
    ///
    /// Always re-reads first: the user may have edited the file since we last
    /// looked, and their edits outside this region must survive.
    static func updateRegion(_ region: Region, at url: URL, to body: String) throws {
        let existing = try String(contentsOf: url, encoding: .utf8)
        let updated = try replacing(
            region, with: body, in: existing, path: url.lastPathComponent)
        try write(updated, to: url)
    }
}
