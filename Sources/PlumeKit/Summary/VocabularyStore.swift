import Foundation

/// Your names, products and jargon, as one markdown file you edit yourself.
///
/// **What this can and cannot fix.** Transcription happens first, and Parakeet
/// exposes no hotword or biasing hook — FluidAudio's only `vocabulary` is the
/// model's own fixed token table — so by the time anything here is read, a
/// misheard term is already in the transcript and the audio is deleted. What a
/// glossary buys is the *summary*: the model can recognise "Kodi" as your
/// colleague Cody and write the name correctly in the document you keep. It is
/// repair, not prevention, and the transcript stays as it was heard.
///
/// One global file rather than one per meeting: the jargon that matters is your
/// company's, your products' and your colleagues' — stable across meetings, and
/// a per-meeting file would be friction at exactly the moment you least want it.
/// If per-meeting terms ever prove necessary, the place for them is a region in
/// `meeting.md`, not a second kind of file.
///
/// Same premise as `TemplateStore`: a markdown file in a folder, seeded once,
/// never overwritten, cached on its own mtime.
enum VocabularyStore {

    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Plume/Vocabulary.md")
    }

    /// The seed is entirely HTML comments and therefore reads as **empty** —
    /// `contents()` strips comments before deciding. That matters: a file nobody
    /// has edited must not put an empty section, or a worked example, into every
    /// prompt for the rest of time. The examples are visible in the editor and
    /// invisible to the model until you replace them with your own lines.
    static let seed = """
        <!--
        Plume vocabulary — names, products and jargon used in your meetings.

        Transcription is automatic and renders unfamiliar words phonetically:
        "Cody" becomes "Kodi", "Datadog" becomes "data dog". Listing a term here
        lets the summary write it correctly, even though the transcript got it
        wrong. It cannot fix the transcript itself — that is produced before this
        file is read, and the audio is gone by then.

        Write plain lines. A short gloss helps more than the bare word:

            Cody — engineer on the platform team
            Kestrel — our scheduling service, not the bird
            DER — diarization error rate

        Everything inside these comment markers is ignored, so this file counts
        as empty until you add lines of your own outside them. Delete the markers
        (or write below them) to start.
        -->
        """

    /// Write the seed if the file is absent. Never touches an existing file.
    @discardableResult
    static func seedIfNeeded() throws -> Bool {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        try (seed + "\n").write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// Strip HTML comments, then trim. Empty means "no vocabulary" — which is
    /// the state of a freshly seeded file, and the state of one somebody emptied.
    static func strippingComments(_ text: String) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "<!--") {
            out += rest[rest.startIndex..<open.lowerBound]
            guard let close = rest.range(of: "-->", range: open.upperBound..<rest.endIndex) else {
                // Unterminated comment: everything after it is commented out.
                return out.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            rest = rest[close.upperBound...]
        }
        out += rest
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Cached on the file's own modification date — see `MTimeCache`.
    private static let cache = MTimeCache<Date, String>()

    private static func fingerprint() -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    /// The user's vocabulary, or empty if they have not written one.
    static func contents() -> String {
        cache.value(fingerprint: fingerprint) {
            try? seedIfNeeded()
            return strippingComments((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        }
    }
}
