import Foundation

/// Single source of truth for everything the UI shows.
///
/// Replaces Quill's `statusHandler`, which was one closure slot on
/// `TranscriptionCoordinator`: installing a second consumer silently displaced
/// the first. That is fine for a menu bar alone, but Phases 2–5 each add
/// failure modes (diarizer model missing, Ollama unreachable, tap gone silent,
/// summarization failed) and Phases 5–6 add a panel and a window that need the
/// same state. Fanning out from one observable object is ~30 lines and avoids
/// retrofitting later. See docs/PLAN.md, "What we inherit that needs fixing".
@MainActor
@Observable
public final class AppState {
    public enum Recording: Equatable {
        case idle
        case recording(since: Date)

        public var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }
    }

    public enum Transcription: Equatable {
        case idle
        case working(name: String, queued: Int)
        case failed(name: String)
    }

    /// A problem worth showing the user. Errors are sticky — they stay until
    /// explicitly dismissed or superseded — because a menubar app has no
    /// console, and a failure that scrolls past unseen is a failure that
    /// silently costs a meeting.
    public struct Failure: Equatable {
        public let message: String
        public let at: Date

        public var age: String {
            let seconds = Int(Date().timeIntervalSince(at))
            if seconds < 60 { return "just now" }
            if seconds < 3600 { return "\(seconds / 60)m ago" }
            return "\(seconds / 3600)h ago"
        }
    }

    public var recording: Recording = .idle
    public var transcription: Transcription = .idle
    public private(set) var lastFailure: Failure?

    /// Meetings recorded but not yet transcribed. Surfaced so a stuck queue is
    /// visible rather than inferred from a folder listing.
    public var pendingCount: Int = 0

    public init() {}

    public func report(_ message: String) {
        lastFailure = Failure(message: message, at: Date())
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    }

    public func clearFailure() {
        lastFailure = nil
    }

    /// Elapsed wall-clock time of the current recording, formatted for display.
    public var elapsedText: String? {
        guard case .recording(let since) = recording else { return nil }
        let total = Int(Date().timeIntervalSince(since))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
