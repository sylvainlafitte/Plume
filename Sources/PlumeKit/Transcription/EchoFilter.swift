import Foundation

/// Drops mic segments that are echoes of system playback.
///
/// When a meeting plays through the speakers and the mic records raw, the mic
/// hears the speakers — everything the far end says is transcribed twice, once
/// from the system tap and again from the mic, often *louder* than the user's
/// own voice. Upstream measured 477 of 641 "me" segments as echo in a 42-minute
/// meeting; Plume reproduced it on the first real recording (3 of 7 segments).
///
/// Matching is word-level and fuzzy because the two tracks transcribe the same
/// audio slightly differently — our own capture produced "chatbot"/"chat bot",
/// "Kodi"/"Cody", "trading files"/"creating files". String equality catches none
/// of those. Far-end windows are padded because the room path lags the system
/// tap and the segmenter draws boundaries loosely.
///
/// Cherry-picked from digimata/quill#25, with one change: upstream compares
/// against the literal speaker `"them"`, which was correct before diarization.
/// Once the system track is split into S1/S2… the far end is no longer one
/// label, so this matches *any* non-mic speaker.
///
/// `mic_voice_processing` prevents the echo at capture; this pass guards
/// sessions recorded raw (the default) or where the voice unit fell back.
enum EchoFilter {
    /// How far (ms) beyond a far-end segment's span a mic segment still counts
    /// as overlapping it.
    private static let overlapPadMs = 400
    /// Word containment at or above this marks a mic segment as echo.
    private static let containmentThreshold = 0.7

    struct Result {
        let segments: [Transcript.Segment]
        let dropped: Int
    }

    /// Returns `segments` without the mic segments judged to be echo, plus a
    /// count so the drop can be logged. Nothing is ever removed silently.
    static func dropEchoes(_ segments: [Transcript.Segment]) -> Result {
        let farEnd = segments.filter { $0.speaker != Speaker.me.label }
        guard !farEnd.isEmpty else { return Result(segments: segments, dropped: 0) }

        var kept: [Transcript.Segment] = []
        var dropped = 0
        for segment in segments {
            if segment.speaker == Speaker.me.label, isEcho(segment, of: farEnd) {
                dropped += 1
            } else {
                kept.append(segment)
            }
        }
        return Result(segments: kept, dropped: dropped)
    }

    private static func isEcho(_ mic: Transcript.Segment, of farEnd: [Transcript.Segment])
        -> Bool
    {
        let overlapping = farEnd.filter {
            min(mic.end_ms, $0.end_ms + overlapPadMs)
                > max(mic.start_ms, $0.start_ms - overlapPadMs)
        }
        guard !overlapping.isEmpty else { return false }

        let micWords = words(mic.text)
        // Punctuation-only, inside far-end speech: echo residue.
        guard !micWords.isEmpty else { return true }
        let farWords = overlapping.flatMap { words($0.text) }

        let contained =
            Double(subsequenceLength(of: micWords, in: farWords)) / Double(micWords.count)
        // One- and two-word segments ("um", "yeah") match too easily — only an
        // exact hit drops them, so genuine backchannels survive.
        return micWords.count <= 2
            ? contained == 1.0
            : contained >= containmentThreshold
    }

    /// Lowercased words with punctuation stripped (apostrophes kept), so
    /// "Right?!" and "right" compare equal.
    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "'" || $0 == " " }
            .split(separator: " ")
            .map(String.init)
    }

    /// Longest common subsequence length: how many of `a`'s words appear in `b`
    /// in the same order, gaps allowed. Segments are sentence-sized, so the
    /// quadratic table is nothing.
    private static func subsequenceLength(of a: [String], in b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var prev = [Int](repeating: 0, count: b.count + 1)
        var curr = prev
        for i in 1...a.count {
            for j in 1...b.count {
                curr[j] =
                    a[i - 1] == b[j - 1]
                    ? prev[j - 1] + 1
                    : max(prev[j], curr[j - 1])
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }
}
