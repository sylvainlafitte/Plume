import Foundation

/// A stable, machine-local identifier for this Mac.
///
/// Exists for one reason: the meetings root may be a synced folder (iCloud
/// Drive, Dropbox) shared by two Macs. `.plume/state.json` is the work queue,
/// so without this a second Mac's `resumePending()` would happily pick up a
/// session the *first* Mac recorded and adopt it — transcribing audio that may
/// still be mid-download, then deleting it. The audio is unrecoverable, so the
/// cheap guard is worth its ten lines.
///
/// Deliberately **not** derived from the host name (users rename Macs) and
/// deliberately stored beside `config.json` rather than in the meetings root —
/// the whole point is that it must never sync.
enum MachineID {

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/plume/machine-id")

    /// This Mac's id, minted on first use. Falls back to a fresh (unpersisted)
    /// id if the file can't be written: a session then looks foreign to every
    /// later launch, which is the safe direction — it rests instead of being
    /// adopted.
    static let current: String = {
        if let existing = try? String(contentsOf: path, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let minted = UUID().uuidString
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? minted.write(to: path, atomically: true, encoding: .utf8)
        return minted
    }()
}
