import Foundation
import Testing

@testable import PlumeKit

@Suite("Speaker labels")
struct SpeakerTests {
    @Test("labels round-trip through their on-disk form")
    func roundTrip() {
        for speaker in [Speaker.me, .them, .remote(1), .remote(12)] {
            #expect(Speaker(label: speaker.label) == speaker)
        }
    }

    @Test("remote speakers are anonymous session-local indices")
    func remoteLabels() {
        #expect(Speaker.remote(1).label == "S1")
        #expect(Speaker.remote(3).label == "S3")
    }

    @Test("an unrecognized label degrades to them, never crashes")
    func unknownLabel() {
        // Reading a transcript written by a future version must not trap.
        #expect(Speaker(label: "Marie") == .them)
        #expect(Speaker(label: "") == .them)
        #expect(Speaker(label: "S") == .them)
    }
}

@Suite("Transcript segments")
struct TranscriptSegmentTests {
    @Test("word timings survive the engine boundary")
    func wordsPreserved() {
        let words = [
            Word(text: "hello", start: 0.0, end: 0.4),
            Word(text: "there", start: 0.5, end: 0.9),
        ]
        let segment = TranscriptSegment(start: 0, end: 0.9, text: "hello there", words: words)
        #expect(segment.words.count == 2)
        #expect(segment.words.first?.text == "hello")
    }

    @Test("segments without word timings are still valid")
    func wordsOptional() {
        // ParakeetEngine falls back to a whole-result segment when the model
        // returns no token timings; that path must stay representable.
        let segment = TranscriptSegment(start: 0, end: 5, text: "whole result")
        #expect(segment.words.isEmpty)
    }

    @Test("tie-breaking makes merge order deterministic")
    func deterministicOrder() {
        // Two speakers starting on the same millisecond is common once
        // diarization splits the system track; unstable sort would make the
        // transcript differ between identical runs.
        func sorted(_ input: [Transcript.Segment]) -> [Transcript.Segment] {
            input.sorted { a, b in
                if a.start_ms != b.start_ms { return a.start_ms < b.start_ms }
                if a.end_ms != b.end_ms { return a.end_ms < b.end_ms }
                if a.speaker != b.speaker { return a.speaker < b.speaker }
                return a.text < b.text
            }
        }
        let a = Transcript.Segment(speaker: "S2", start_ms: 100, end_ms: 200, text: "second")
        let b = Transcript.Segment(speaker: "S1", start_ms: 100, end_ms: 200, text: "first")
        #expect(sorted([a, b]) == sorted([b, a]))
        #expect(sorted([a, b]).first?.speaker == "S1")
    }
}
