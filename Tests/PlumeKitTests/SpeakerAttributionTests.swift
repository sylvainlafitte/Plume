import Foundation
import Testing

@testable import PlumeKit

@Suite("Speaker attribution")
struct SpeakerAttributionTests {

    private func words(_ specs: [(String, Double, Double)]) -> [Word] {
        specs.map { Word(text: $0.0, start: $0.1, end: $0.2) }
    }

    private func segment(_ specs: [(String, Double, Double)]) -> TranscriptSegment {
        let w = words(specs)
        return TranscriptSegment(
            start: w.first!.start, end: w.last!.end,
            text: w.map(\.text).joined(separator: " "), words: w)
    }

    private func turn(_ id: String, _ start: Double, _ end: Double, quality: Float = 1.0)
        -> DiarizedTurn
    {
        DiarizedTurn(speakerId: id, start: start, end: end, quality: quality)
    }

    @Test("a segment spanning a speaker change is split at the boundary")
    func splitsOnSpeakerChange() {
        // The core reason word timings are preserved: one ASR segment, two speakers.
        let input = segment([
            ("hello", 0.0, 0.5), ("there", 0.6, 1.0),
            ("hi", 2.0, 2.4), ("back", 2.5, 3.0),
        ])
        let result = SpeakerAttribution.attribute(
            segments: [input],
            turns: [turn("a", 0.0, 1.2), turn("b", 1.8, 3.2)],
            fallback: .them)

        #expect(result.count == 2)
        #expect(result[0].speaker == .remote(1))
        #expect(result[0].text == "hello there")
        #expect(result[1].speaker == .remote(2))
        #expect(result[1].text == "hi back")
    }

    @Test("a single detected speaker stays 'them' rather than becoming S1")
    func singleSpeakerKeepsFallback() {
        // "S1" claims more than we know and reads worse than the honest label.
        let input = segment([("just", 0.0, 0.4), ("me", 0.5, 0.9)])
        let result = SpeakerAttribution.attribute(
            segments: [input], turns: [turn("a", 0.0, 1.0)], fallback: .them)

        #expect(result.count == 1)
        #expect(result[0].speaker == .them)
    }

    @Test("no diarization at all degrades to the track label")
    func noTurnsDegrades() {
        let input = segment([("hello", 0.0, 0.5)])
        let result = SpeakerAttribution.attribute(
            segments: [input], turns: [], fallback: .them)
        #expect(result.map(\.speaker) == [.them])
    }

    @Test("low-quality turns are ignored, not trusted")
    func lowQualityIgnored() {
        // Two speakers, but both below the quality floor: fall back rather than
        // inventing an attribution.
        let input = segment([("a", 0.0, 0.4), ("b", 2.0, 2.4)])
        let result = SpeakerAttribution.attribute(
            segments: [input],
            turns: [turn("x", 0.0, 1.0, quality: 0.1), turn("y", 1.8, 3.0, quality: 0.2)],
            fallback: .them)
        #expect(result.allSatisfy { $0.speaker == .them })
    }

    @Test("a word barely grazing a turn is not attributed to it")
    func weakOverlapFallsBack() {
        // Word runs 0.0–1.0; the S1 turn covers only 0.2s of it (20% < 50%).
        // The other speaker gives us two distinct ids so attribution is active.
        let input = segment([("straddling", 0.0, 1.0)])
        let result = SpeakerAttribution.attribute(
            segments: [input],
            turns: [turn("a", 0.0, 0.2), turn("b", 5.0, 6.0)],
            fallback: .them)
        #expect(result[0].speaker == .them)
    }

    @Test("speaker numbering follows first appearance, not clusterer order")
    func numberingByFirstAppearance() {
        let input = segment([("second", 5.0, 5.4), ("first", 0.0, 0.4)])
        let result = SpeakerAttribution.attribute(
            segments: [input],
            // "z" speaks first in time but is listed second.
            turns: [turn("a", 4.8, 6.0), turn("z", 0.0, 1.0)],
            fallback: .them)
        let bySpeaker = Dictionary(uniqueKeysWithValues: result.map { ($0.text, $0.speaker) })
        #expect(bySpeaker["first"] == .remote(1))
        #expect(bySpeaker["second"] == .remote(2))
    }

    @Test("segments without word timings are attributed as a unit")
    func noWordTimings() {
        let input = TranscriptSegment(start: 0, end: 1, text: "whole thing")
        let result = SpeakerAttribution.attribute(
            segments: [input],
            turns: [turn("a", 0.0, 1.0), turn("b", 5.0, 6.0)],
            fallback: .them)
        #expect(result.count == 1)
        #expect(result[0].speaker == .remote(1))
    }

    @Test("output stays ordered by start time")
    func ordered() {
        let a = segment([("later", 10.0, 10.5)])
        let b = segment([("earlier", 1.0, 1.5)])
        let result = SpeakerAttribution.attribute(
            segments: [a, b],
            turns: [turn("x", 0.0, 2.0), turn("y", 9.0, 11.0)],
            fallback: .them)
        #expect(result.map(\.start) == result.map(\.start).sorted())
    }
}
