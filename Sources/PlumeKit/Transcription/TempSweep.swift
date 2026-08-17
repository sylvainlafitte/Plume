import Foundation

/// Delete FluidAudio's abandoned scratch files at launch.
///
/// Diarization converts the whole track to 16 kHz mono float32 in
/// `temporaryDirectory` before mmapping it — roughly 460 MB for a two-hour
/// meeting — and deletes it on completion. A crash or a force-quit mid-transcribe
/// skips that, and macOS only clears `/var/folders` on its own schedule, which
/// can be weeks. Nothing in Plume noticed, so the disk just filled.
///
/// Deliberately narrow: it deletes files matching FluidAudio's own naming, and
/// only ones old enough that no live run could own them. A sweep that guessed
/// would be deleting other processes' data in a shared directory.
enum TempSweep {

    /// FluidAudio's prefix, from `AudioSourceFactory.makeTemporaryURL`.
    static let prefix = "fluidaudio-streaming-"
    static let suffix = ".raw"

    /// Anything younger than this might belong to a transcription running right
    /// now — our own, or a second Plume on a synced meetings folder. An hour is
    /// far longer than a conversion takes and far shorter than the leak matters.
    static let minimumAge: TimeInterval = 3600

    /// Pure selection, so the policy is testable without a filesystem.
    static func isStale(name: String, age: TimeInterval) -> Bool {
        name.hasPrefix(prefix) && name.hasSuffix(suffix) && age >= minimumAge
    }

    /// Returns the files it removed, for the log line. Failures are ignored on
    /// purpose: this is housekeeping, and a temp file we cannot delete is not a
    /// reason to interrupt a launch.
    @discardableResult
    static func run(
        in directory: URL = FileManager.default.temporaryDirectory,
        now: Date = Date()
    ) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        var removed: [String] = []
        for url in entries {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            guard isStale(name: url.lastPathComponent, age: now.timeIntervalSince(modified))
            else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed.append(url.lastPathComponent)
            }
        }
        return removed
    }
}
