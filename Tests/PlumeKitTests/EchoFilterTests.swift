import Foundation
import Testing

@testable import PlumeKit

@Suite("Echo filter")
struct EchoFilterTests {
    private func seg(_ speaker: String, _ start: Int, _ end: Int, _ text: String)
        -> Transcript.Segment
    {
        Transcript.Segment(speaker: speaker, start_ms: start, end_ms: end, text: text)
    }

    @Test("drops a mic copy that differs slightly from the far-end text")
    func dropsFuzzyDuplicate() {
        // Taken verbatim from Plume's first real recording: the two tracks
        // transcribed the same speech differently, so exact matching fails.
        let segments = [
            seg("them", 4000, 8000, "A chatbot that I say things to and it intelligently says things back to me."),
            seg("me", 4000, 8000, "A chat bot that I say things to and it intelligently says things back to me."),
        ]
        let result = EchoFilter.dropEchoes(segments)
        #expect(result.dropped == 1)
        #expect(result.segments.map(\.speaker) == ["them"])
    }

    @Test("keeps genuine cross-talk over far-end speech")
    func keepsCrossTalk() {
        let segments = [
            seg("them", 0, 5000, "so the migration should finish by Thursday at the latest"),
            seg("me", 1000, 2000, "no I I I do get you but what about the rollback plan"),
        ]
        let result = EchoFilter.dropEchoes(segments)
        #expect(result.dropped == 0)
        #expect(result.segments.count == 2)
    }

    @Test("short backchannels survive unless they match exactly")
    func backchannels() {
        // "yeah" while the far end says something else entirely: keep it.
        let kept = EchoFilter.dropEchoes([
            seg("them", 0, 5000, "the deadline moved to next quarter"),
            seg("me", 1000, 1400, "yeah"),
        ])
        #expect(kept.dropped == 0)

        // "yeah" while the far end also says exactly "yeah": echo.
        let dropped = EchoFilter.dropEchoes([
            seg("them", 0, 2000, "yeah"),
            seg("me", 0, 2000, "yeah"),
        ])
        #expect(dropped.dropped == 1)
    }

    @Test("matches diarized far-end labels, not just 'them'")
    func matchesNumberedSpeakers() {
        // Upstream compared against the literal "them"; after diarization the
        // far end is S1/S2, and echo must still be caught.
        let segments = [
            seg("S1", 0, 4000, "we should push the launch to the following week"),
            seg("me", 0, 4000, "we should push the launch to the following week"),
        ]
        let result = EchoFilter.dropEchoes(segments)
        #expect(result.dropped == 1)
        #expect(result.segments.map(\.speaker) == ["S1"])
    }

    @Test("a mic segment outside any far-end span is never echo")
    func nonOverlappingKept() {
        let segments = [
            seg("them", 0, 2000, "hello there"),
            seg("me", 60000, 62000, "hello there"),
        ]
        #expect(EchoFilter.dropEchoes(segments).dropped == 0)
    }

    @Test("with no far-end track nothing is dropped")
    func micOnlySessionUntouched() {
        let segments = [
            seg("me", 0, 1000, "just me talking"),
            seg("me", 2000, 3000, "still just me"),
        ]
        let result = EchoFilter.dropEchoes(segments)
        #expect(result.dropped == 0)
        #expect(result.segments.count == 2)
    }

    @Test("order of surviving segments is preserved")
    func orderPreserved() {
        let segments = [
            seg("me", 0, 500, "opening remark from me"),
            seg("them", 1000, 3000, "a reply from the far end"),
            seg("me", 1000, 3000, "a reply from the far end"),
            seg("me", 4000, 4500, "closing remark from me"),
        ]
        let result = EchoFilter.dropEchoes(segments)
        #expect(result.dropped == 1)
        #expect(result.segments.map(\.text) == [
            "opening remark from me", "a reply from the far end", "closing remark from me",
        ])
    }
}
