import FluidAudio
import Foundation

/// Fetching the on-device models *deliberately*, with progress, instead of
/// letting the first meeting do it lazily.
///
/// PLAN R7. Both engines call `downloadAndLoad` / `prepareModels` on first use,
/// which on a fresh machine means the first recording appears to hang for as
/// long as ~600 MB takes to arrive — after the meeting is over, when there is
/// nothing to look at and no way to tell a slow download from a broken app.
/// Worse, **this cannot be reproduced on a machine that has a warm cache**
/// (logged 2026-08-14), so the path a stranger hits first is the one least
/// likely to be tested.
///
/// Like every other FluidAudio call, this sits behind our own type so a version
/// bump is a one-file diff (AGENTS.md §4).
enum ModelSetup {

    /// What the UI needs to draw, without knowing anything about FluidAudio.
    enum Phase: Equatable, Sendable {
        case listing
        case downloading(fraction: Double)
        /// CoreML compilation. It reports no fraction and can take a while on a
        /// first launch, so it is a distinct phase rather than a stalled bar.
        case compiling(model: String)
    }

    struct Progress: Equatable, Sendable {
        let component: String
        let phase: Phase
    }

    /// Which model sets are already on disk. Read cheaply, so it can drive a
    /// launch-time decision without touching the network.
    static var transcriptionReady: Bool {
        AsrModels.modelsExist(
            at: AsrModels.defaultCacheDirectory(for: .v2), version: .v2)
    }

    /// The diarizer ships no `modelsExist`, so this is a directory probe: the
    /// repo folder exists and is non-empty. Coarser than the ASR check by
    /// necessity — treat it as "probably there", and let `prepare()` be the
    /// authority, exactly as it already is.
    static var diarizationReady: Bool {
        let dir = OfflineDiarizerModels.defaultModelsDirectory()
        let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        return !(contents ?? []).isEmpty
    }

    static var allReady: Bool { transcriptionReady && diarizationReady }

    /// Approximate download size, for a sentence that lets someone decide
    /// whether to do this on the connection they are currently on.
    static let approximateDownloadMB = 700

    /// Fetch whatever is missing, reporting progress. Safe to call when
    /// everything is present: both underlying calls short-circuit.
    ///
    /// `onProgress` is called from an unspecified queue — FluidAudio says so
    /// explicitly — so callers must hop to the main actor themselves.
    static func downloadIfNeeded(
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws {
        if !transcriptionReady {
            _ = try await AsrModels.download(version: .v2) { progress in
                onProgress(Progress(
                    component: "Transcription",
                    phase: Phase(progress)))
            }
        }
        if !diarizationReady {
            // `prepareModels` exposes no progress handler, but `load` does, and
            // it populates the same cache — so we load once to get a progress
            // bar, then discard. The engine's own `prepare()` finds the files
            // already there and skips straight to loading them.
            _ = try await OfflineDiarizerModels.load { progress in
                onProgress(Progress(
                    component: "Speaker separation",
                    phase: Phase(progress)))
            }
        }
    }
}

extension ModelSetup.Phase {
    init(_ progress: DownloadProgress) {
        switch progress.phase {
        case .listing:
            self = .listing
        case .downloading:
            self = .downloading(fraction: progress.fractionCompleted)
        case .compiling(let name):
            self = .compiling(model: name)
        }
    }
}
