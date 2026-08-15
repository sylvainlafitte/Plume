import SwiftUI

/// Renders the small markdown subset our summary templates actually emit.
///
/// SwiftUI's `Text` understands *inline* markdown only — bold, italic, code,
/// links — and silently leaves `##` and `-` as literal characters, which is
/// exactly what a summary is made of. Rather than take a markdown dependency
/// (see AGENTS.md), this handles the known subset: headings, bullets, task
/// items, blockquotes and paragraphs, with inline styling delegated to
/// `AttributedString` so bold and links still work inside a line.
///
/// Anything it doesn't recognise falls through as a paragraph, so a template
/// that emits something unexpected degrades to plain text rather than vanishing.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlock.parse(markdown).enumerated()), id: \.offset) {
                _, block in
                switch block {
                case .heading(let level, let text):
                    Text(inline(text))
                        .font(level <= 2 ? .headline : .subheadline)
                        .padding(.top, 4)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(text)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .task(let done, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: done ? "checkmark.square" : "square")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(inline(text)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .quote(let text):
                    Text(inline(text))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(.quaternary).frame(width: 2)
                        }
                case .paragraph(let text):
                    Text(inline(text)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    /// Inline styling via AttributedString; falls back to plain text if the
    /// line isn't valid inline markdown.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Block-level structure. Split out so it can be tested without a view.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(String)
    case task(done: Bool, text: String)
    case quote(String)
    case paragraph(String)

    static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []

        func flushParagraph() {
            let joined = paragraph.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph = []
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.isEmpty {
                flushParagraph()
                continue
            }
            if line.hasPrefix("#") {
                flushParagraph()
                let hashes = line.prefix { $0 == "#" }.count
                let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { blocks.append(.heading(level: hashes, text: text)) }
                continue
            }
            // Task items are checked before plain bullets — "- [ ] x" is both.
            if let task = taskItem(line) {
                flushParagraph()
                blocks.append(task)
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                blocks.append(.bullet(String(line.dropFirst(2))))
                continue
            }
            if line.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(line.dropFirst(2))))
                continue
            }
            // Wrapped prose: keep accumulating until a blank line.
            paragraph.append(line)
        }
        flushParagraph()
        return blocks
    }

    private static func taskItem(_ line: String) -> MarkdownBlock? {
        for marker in ["- ", "* "] where line.hasPrefix(marker) {
            let rest = line.dropFirst(marker.count)
            guard rest.hasPrefix("[") , rest.count > 3 else { continue }
            let box = rest.dropFirst().prefix(1)
            guard rest.dropFirst(2).hasPrefix("] ") else { continue }
            let done = box.lowercased() == "x"
            return .task(done: done, text: String(rest.dropFirst(4)))
        }
        return nil
    }
}
