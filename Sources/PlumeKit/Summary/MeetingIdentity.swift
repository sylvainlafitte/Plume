import Foundation

/// A proposed name for a speaker label, with the evidence behind it.
struct SpeakerProposal: Codable, Sendable, Equatable {
    let label: String
    let name: String
    let confidence: Double
    let evidence: String
}

/// What the model inferred about a meeting: what to call it, and who was in it.
struct MeetingIdentity: Codable, Sendable, Equatable {
    var title: String?
    var speakers: [SpeakerProposal]

    /// Stored beside the pipeline state, never written into the transcript.
    static func url(in session: URL) -> URL {
        SessionState.directory(in: session).appendingPathComponent("proposals.json")
    }

    static func load(from session: URL) -> MeetingIdentity? {
        guard let data = try? Data(contentsOf: url(in: session)) else { return nil }
        return try? JSONDecoder().decode(MeetingIdentity.self, from: data)
    }

    func save(to session: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url(in: session), options: .atomic)
    }
}

/// Derives a meeting title and speaker names from what was said.
///
/// **Names are proposals, never applied** (invariant 3). A wrong name attributes
/// quotes to a real person who did not say them, which is materially worse than
/// an honest `S1` — so these land in `.plume/proposals.json` and wait for one
/// human click in the wrap-up panel. The *title* is applied automatically:
/// it labels the meeting rather than attributing speech, and a wrong one is
/// obvious and harmless.
///
/// Signals, strongest first — note most live in the transcript, not the notes:
///   1. self-introduction ("Hi, I'm Marie")
///   2. a vocative aimed at the far end ("Thanks, Tom")
///   3. turn adjacency after a direct address
///   4. names written in the attendee's notes — who was there, but not who spoke
enum MeetingIdentityDeriver {

    /// Constrained decoding. Beyond reliable parsing, a schema bounds the
    /// injection surface: a response that must match this shape cannot wander
    /// off into whatever someone said aloud during the call.
    static let schema = """
        {
          "type": "object",
          "properties": {
            "title": { "type": "string" },
            "speakers": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "label": { "type": "string" },
                  "name": { "type": "string" },
                  "confidence": { "type": "number" },
                  "evidence": { "type": "string" }
                },
                "required": ["label", "name", "confidence", "evidence"]
              }
            }
          },
          "required": ["title", "speakers"]
        }
        """

    static let system = """
        You extract two things from a meeting transcript: a short title, and the \
        real names of the speaker labels where the transcript actually reveals them.

        Title: 3–6 words naming what the meeting was about. No date, no the word \
        "meeting", no quotes.

        Speakers: for each label, propose a name ONLY if the transcript supports it — \
        someone introduces themselves, someone is addressed by name and then replies, \
        or a name is clearly attached to a label. Give confidence 0–1 and quote the \
        exact phrase you used as evidence.

        Never guess. Omit a speaker entirely rather than proposing a name you \
        inferred from context, plausibility, or common sense. An omission costs \
        nothing; a wrong name puts words in a real person's mouth.

        Never propose a name for the label "me" — that is the person reading this.
        """

    /// Below this, a proposal is noise and is discarded rather than shown.
    static let confidenceFloor = 0.6

    static func derive(
        transcript: String, notes: String, client: OllamaClient
    ) async throws -> MeetingIdentity {
        // The glossary is how "Kodi" becomes a proposal to name a speaker Cody,
        // and how a product name reaches the title spelled the way you spell it.
        let user = Prompt.identity(
            transcript: transcript, notes: notes, vocabulary: VocabularyStore.contents())
        let response = try await client.chat(
            system: system, user: user,
            format: Data(schema.utf8),
            keepAlive: "5m")

        guard let data = response.data(using: .utf8),
            var identity = try? JSONDecoder().decode(MeetingIdentity.self, from: data)
        else { throw SummaryError.emptyResponse }

        identity.speakers = identity.speakers.filter {
            $0.confidence >= confidenceFloor
                && $0.label != Speaker.me.label
                && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
        }
        identity.title = identity.title?.trimmingCharacters(
            in: CharacterSet(charactersIn: " \"'"))
        return identity
    }

    /// Filesystem-safe slug for the folder name.
    static func slug(_ title: String) -> String {
        let allowed = title.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String(collapsed.prefix(60))
    }
}
