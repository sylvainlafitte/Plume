import Foundation

/// One recognized word with its own timing.
///
/// Quill collapsed these away inside `ParakeetEngine` as soon as it had grouped
/// them into segments. Phase 2 needs them: a segment can run up to 60 words and
/// routinely spans a speaker change, so attributing speakers *per segment* would
/// smear turns together. Diarization assigns a speaker per word, then segments
/// are rebuilt on speaker boundaries. See docs/PLAN.md F6.
struct Word: Sendable, Codable, Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

/// One timed span of recognized speech from a single track, relative to that
/// track's own start.
struct TranscriptSegment: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    /// Word-level timings backing this segment, in order. May be empty when the
    /// engine produced no token timings (the fallback path in ParakeetEngine).
    let words: [Word]

    init(start: TimeInterval, end: TimeInterval, text: String, words: [Word] = []) {
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }
}

/// Who is speaking in a segment.
///
/// Two-track capture gives `me` and `them` for free, before any model runs.
/// Diarization only has to split the *remote* track further, so `remote(n)`
/// carries anonymous session-local indices ("S1", "S2"), never a real name until
/// a human confirms one — a wrong name attributes quotes to someone who didn't
/// say them, which is worse than an honest S1 (docs/PLAN.md invariant 3).
enum Speaker: Sendable, Equatable, Hashable {
    case me
    case them
    case remote(Int)

    /// Stable identifier written to disk.
    var label: String {
        switch self {
        case .me: return "me"
        case .them: return "them"
        case .remote(let n): return "S\(n)"
        }
    }

    init(label: String) {
        switch label {
        case "me": self = .me
        case "them": self = .them
        default:
            if label.hasPrefix("S"), let n = Int(label.dropFirst()) {
                self = .remote(n)
            } else {
                self = .them
            }
        }
    }
}

/// A speech-to-text engine Plume can run locally. Engines are prepared lazily
/// (model download + load) when the transcription queue has work and released
/// when it drains, so Plume never idles holding gigabytes of model weights.
protocol TranscriptionEngine: Sendable {
    /// Short engine identifier recorded as transcript.json provenance.
    var name: String { get }
    /// Concrete model identifier recorded as transcript.json provenance.
    var model: String { get }
    func prepare() async throws
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment]
    func release() async
}
