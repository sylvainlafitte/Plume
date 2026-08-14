import Foundation

/// A span of speech with a speaker attached, ready to be written to a transcript.
struct AttributedSegment: Sendable, Equatable {
    let speaker: Speaker
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// Joins ASR output to diarizer output.
///
/// FluidAudio deliberately does not compose these — the caller matches them. The
/// naive approach, tagging each ASR segment with its dominant speaker, is wrong
/// here: `ParakeetEngine` groups up to 60 words per segment, so a segment
/// routinely spans a speaker change and would smear two turns into one. So
/// speakers are assigned **per word**, then segments are rebuilt on speaker
/// boundaries. See docs/PLAN.md F6.
enum SpeakerAttribution {

    /// Minimum share of a word's duration that must overlap a diarized turn
    /// before we believe the attribution.
    static let minOverlapFraction = 0.5

    /// Minimum diarizer quality for a turn to be trusted.
    static let minTurnQuality: Float = 0.5

    /// Attribute `segments` (from one track) using `turns`, falling back to
    /// `fallback` wherever the evidence is weak.
    ///
    /// Adopted from digimata/quill#20: emit a numbered speaker only when the
    /// alignment clears a threshold, otherwise keep the honest track-level label.
    /// An `S2` invented from a weak overlap is worse than an accurate `them` —
    /// it puts words in a specific person's mouth.
    static func attribute(
        segments: [TranscriptSegment],
        turns: [DiarizedTurn],
        fallback: Speaker
    ) -> [AttributedSegment] {
        let usable = turns.filter { $0.quality >= minTurnQuality && $0.end > $0.start }
        let distinctSpeakers = Set(usable.map(\.speakerId))

        // With one speaker there is nothing to separate, and "S1" reads worse
        // than "them" while claiming more. Also covers the empty case.
        guard distinctSpeakers.count > 1 else {
            return segments.map {
                AttributedSegment(
                    speaker: fallback, start: $0.start, end: $0.end, text: $0.text)
            }
        }

        // Stable mapping from diarizer ids to remote indices, ordered by first
        // appearance so S1 is whoever spoke first — not whatever order the
        // clusterer happened to emit.
        var indexForSpeaker: [String: Int] = [:]
        for turn in usable.sorted(by: { $0.start < $1.start })
        where indexForSpeaker[turn.speakerId] == nil {
            indexForSpeaker[turn.speakerId] = indexForSpeaker.count + 1
        }

        var out: [AttributedSegment] = []
        for segment in segments {
            // No word timings (the engine's whole-result fallback path): the
            // segment can only be attributed as a unit.
            guard !segment.words.isEmpty else {
                let speaker = dominantSpeaker(
                    from: segment.start, to: segment.end,
                    turns: usable, indexForSpeaker: indexForSpeaker) ?? fallback
                out.append(
                    AttributedSegment(
                        speaker: speaker, start: segment.start, end: segment.end,
                        text: segment.text))
                continue
            }

            let labelled = segment.words.map { word -> (Word, Speaker) in
                let speaker = attributedSpeaker(
                    for: word, turns: usable, indexForSpeaker: indexForSpeaker) ?? fallback
                return (word, speaker)
            }
            out.append(contentsOf: regroup(labelled))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Speaker for a single word, or nil when nothing overlaps it convincingly.
    private static func attributedSpeaker(
        for word: Word, turns: [DiarizedTurn], indexForSpeaker: [String: Int]
    ) -> Speaker? {
        let duration = max(word.end - word.start, 0.001)
        var best: (id: String, overlap: TimeInterval)?
        for turn in turns {
            let overlap = min(word.end, turn.end) - max(word.start, turn.start)
            guard overlap > 0 else { continue }
            if overlap > (best?.overlap ?? 0) { best = (turn.speakerId, overlap) }
        }
        guard let best, best.overlap / duration >= minOverlapFraction,
            let index = indexForSpeaker[best.id]
        else { return nil }
        return .remote(index)
    }

    /// Speaker covering the most of a time range, for segments with no words.
    private static func dominantSpeaker(
        from start: TimeInterval, to end: TimeInterval,
        turns: [DiarizedTurn], indexForSpeaker: [String: Int]
    ) -> Speaker? {
        var totals: [String: TimeInterval] = [:]
        for turn in turns {
            let overlap = min(end, turn.end) - max(start, turn.start)
            if overlap > 0 { totals[turn.speakerId, default: 0] += overlap }
        }
        let span = max(end - start, 0.001)
        guard let (id, overlap) = totals.max(by: { $0.value < $1.value }),
            overlap / span >= minOverlapFraction,
            let index = indexForSpeaker[id]
        else { return nil }
        return .remote(index)
    }

    /// Rebuild segments from per-word speakers, breaking wherever the speaker
    /// changes. This is the step that stops one 60-word ASR segment from
    /// swallowing a turn boundary.
    private static func regroup(_ labelled: [(Word, Speaker)]) -> [AttributedSegment] {
        var out: [AttributedSegment] = []
        var current: [Word] = []
        var currentSpeaker: Speaker?

        func flush() {
            guard let speaker = currentSpeaker, let first = current.first,
                let last = current.last
            else { return }
            out.append(
                AttributedSegment(
                    speaker: speaker,
                    start: first.start,
                    end: last.end,
                    text: current.map(\.text).joined(separator: " ")
                ))
            current = []
        }

        for (word, speaker) in labelled {
            if speaker != currentSpeaker {
                flush()
                currentSpeaker = speaker
            }
            current.append(word)
        }
        flush()
        return out
    }
}
