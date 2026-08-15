import Foundation

/// What a meeting looks like once loaded from disk, for whichever surface is
/// showing it.
///
/// The wrap-up panel and the history window were building this twice, twenty
/// lines apart, and had already diverged. `MeetingDetailView` was extracted to
/// stop exactly that drift; this is the other half of the same extraction.
///
/// Pure functions over a folder, so the loading rules are testable without a
/// window.
enum MeetingContent {

    struct Loaded: Equatable {
        var summary: String
        var speakerRows: [SpeakerRow]
    }

    /// `*pending*` is the placeholder transcription writes into the summary
    /// region so `meeting.md` is complete before any model runs. It is not a
    /// summary and must never be shown as one.
    static func summaryBody(from document: String) -> String {
        guard let existing = try? MeetingDocument.read(.summary, from: document)
        else { return "" }
        return existing == "*pending*" ? "" : existing
    }

    /// Remote speakers only — "me" is you by construction and has nothing to
    /// rename. Proposals ride along unapplied: a derived name waits for one
    /// human click (invariant 3).
    static func speakerRows(session: URL, transcript: String) -> [SpeakerRow] {
        let proposals = MeetingIdentity.load(from: session)?.speakers ?? []
        return SpeakerEditing.speakers(in: transcript)
            .filter { $0.label != Speaker.me.label }
            .map { entry in
                SpeakerRow(
                    label: entry.label, samples: entry.samples,
                    proposal: proposals.first { $0.label == entry.label })
            }
    }

    /// Nil when `meeting.md` isn't there yet — a recorded-but-untranscribed
    /// meeting, which is a normal resting state rather than an error.
    static func load(session: URL) -> Loaded? {
        guard
            let document = try? String(
                contentsOf: session.appendingPathComponent("meeting.md"), encoding: .utf8)
        else { return nil }
        let transcript = (try? MeetingDocument.read(.transcript, from: document)) ?? ""
        return Loaded(
            summary: summaryBody(from: document),
            speakerRows: speakerRows(session: session, transcript: transcript))
    }
}
