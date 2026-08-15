import FluidAudio
import Foundation

/// One span of speech attributed to an anonymous speaker.
///
/// Plume's own vocabulary, not FluidAudio's. Every call into that library goes
/// through this file so a version bump stays a one-file diff — it has made
/// source-breaking changes in patch releases (see AGENTS.md).
struct DiarizedTurn: Sendable, Equatable {
    /// Session-local identifier from the diarizer: "S1", "S2"… Never a name.
    let speakerId: String
    let start: TimeInterval
    let end: TimeInterval
    /// Diarizer confidence in this span. Used to gate attribution — below the
    /// threshold we keep the honest track-level label instead of guessing.
    let quality: Float
}

protocol Diarizing: Sendable {
    var name: String { get }
    func prepare() async throws
    func diarize(_ audio: URL) async throws -> [DiarizedTurn]
    func release() async
}

/// Offline VBx diarization over a complete audio file.
///
/// Deliberately *not* the streaming diarizer. We batch — the file is on disk
/// before we start — and FluidAudio's own AMI-SDM benchmarks put the offline
/// pipeline at 10.6% DER against LS-EEND's 20.7%, with no speaker-count cap.
/// See docs/PLAN.md F1.
///
/// An actor because `OfflineDiarizerManager` is a `public final class` holding
/// `nonisolated(unsafe)` state: it is not `Sendable` and needs an owner, not a
/// protocol existential passed around.
actor OfflineDiarizer: Diarizing {
    nonisolated let name = "pyannote-community-1-vbx"

    /// `OfflineDiarizerManager` carries `nonisolated(unsafe)` state and is not
    /// `Sendable`, so awaiting its async `process` reads to the compiler as
    /// sending it across an isolation boundary.
    ///
    /// This box asserts what the compiler can't see: the manager is created
    /// inside this actor, stored only here, never returned, never passed to
    /// another task, and only ever touched from the actor's isolated methods —
    /// which serialise every access. That is exclusive ownership, not a warning
    /// being papered over.
    ///
    /// If a future change hands the manager to anything else, this assertion
    /// stops being true and the box must go. Re-check on any FluidAudio bump.
    private struct ManagerBox: @unchecked Sendable {
        let manager: OfflineDiarizerManager
    }

    private var box: ManagerBox?

    /// Tuning, all measured rather than guessed — see docs/PLAN.md F1.
    private static func makeConfig(maxSpeakers: Int?) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig(
            // 0.6 (the community default) merges too eagerly and undercounts
            // speakers on meeting audio, degrading the benchmark to 15.5% DER.
            // 0.7 is FluidAudio's own recommendation for AMI-SDM-like material.
            //
            // Caveat worth remembering: 0.7 was tuned on 4-speaker meetings and
            // biases against merging, so the risk case for us is the opposite —
            // a 1:1 split into S1/S2. That's why the 1:1 acceptance test exists.
            clusteringThreshold: 0.7,
            // 0.1 + minSegmentDuration 0 costs about half the throughput and
            // buys 15.07% → 13.89% DER on VoxConverse. We transcribe after the
            // meeting, so throughput is not the constraint.
            segmentationStepRatio: 0.1,
            minSegmentDuration: 0.0
        )
        // Off by default upstream. Without it, zero-vote frames tie-break to
        // cluster 0 and can silently absorb whole speaker turns into the
        // neighbouring speaker — precisely our failure mode.
        config.zeroVoteReembed = .init(enabled: true)

        // The decisive lever for 1:1s, which are the modal meeting. Threshold
        // 0.7 was tuned on 4-speaker AMI material and deliberately biases
        // *against* merging, so its characteristic error on a two-person call is
        // splitting one voice into S1/S2. A hard cap makes that impossible
        // rather than unlikely — and unlike the threshold, it needs no tuning.
        if let maxSpeakers {
            return config.withSpeakers(max: maxSpeakers)
        }
        return config
    }

    private let maxSpeakers: Int?

    /// - Parameter maxSpeakers: upper bound on far-end speakers, or nil for
    ///   unconstrained. See `Config.maxFarEndSpeakers()`.
    init(maxSpeakers: Int?) {
        self.maxSpeakers = maxSpeakers
    }

    func prepare() async throws {
        guard box == nil else { return }
        let box = ManagerBox(
            manager: OfflineDiarizerManager(config: Self.makeConfig(maxSpeakers: maxSpeakers)))
        try await box.manager.prepareModels()
        self.box = box
    }

    func diarize(_ audio: URL) async throws -> [DiarizedTurn] {
        guard let box else { throw DiarizationError.notPrepared }

        let result: DiarizationResult
        do {
            result = try await box.manager.process(audio)
        } catch OfflineDiarizationError.noSpeechDetected {
            // Not a failure. A track with no speech is the normal case for a
            // meeting where nobody joined yet, or one recorded on headphones
            // with nothing playing. Zero turns is the honest answer; reporting
            // it as an error would put a scary line in the log for a healthy run.
            return []
        }
        return result.segments.map {
            DiarizedTurn(
                speakerId: $0.speakerId,
                start: TimeInterval($0.startTimeSeconds),
                end: TimeInterval($0.endTimeSeconds),
                quality: $0.qualityScore
            )
        }
        .sorted { $0.start < $1.start }
    }

    func release() async {
        box = nil
    }
}

enum DiarizationError: Error, CustomStringConvertible {
    case notPrepared

    var description: String {
        switch self {
        case .notPrepared: return "diarizer used before prepare()"
        }
    }
}
