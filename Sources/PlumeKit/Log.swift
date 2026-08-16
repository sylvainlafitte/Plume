import Foundation
import os

/// An app-level log file, so a bug report has something to attach.
///
/// Until now Plume's only durable log was `.plume/transcribe.log`, written per
/// session — useful for a transcription that failed, useless for "it didn't
/// start", "the hotkey does nothing" or anything before a recording exists.
/// Everything else went to stderr, which for a `.app` launched by
/// LaunchServices goes nowhere a user can reach.
///
/// Deliberately a plain text file in `~/Library/Logs/Plume/`, where Console.app
/// and every "collect the logs" instruction already look — not `os_log`, whose
/// contents a user cannot hand over without knowing `log show` incantations.
enum Log {

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Plume", isDirectory: true)

    static var file: URL { directory.appendingPathComponent("plume.log") }

    /// Rotate at 1 MB, keeping one previous file. Small enough to attach to an
    /// email, large enough to hold a long session's worth of events.
    static let maxBytes = 1_000_000

    private static let lock = OSAllocatedUnfairLock(initialState: ())

    /// Appends one timestamped line, and mirrors it to stderr so `swift run`
    /// and the CLI keep behaving as they did.
    static func write(_ message: String) {
        let line = "\(Self.timestamp()) \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))

        lock.withLock {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            rotateIfNeeded()
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: file) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: file)
            }
        }
    }

    /// One previous generation only. A log that grows without bound is the
    /// thing this replaces, and nobody reads the third-oldest file.
    private static func rotateIfNeeded() {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int
        guard let size, size > maxBytes else { return }
        let previous = directory.appendingPathComponent("plume.previous.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: file, to: previous)
    }

    private static func timestamp() -> String {
        // ISO-8601 with seconds: sortable, unambiguous across locales, and the
        // format every other log on the machine uses.
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }
}
