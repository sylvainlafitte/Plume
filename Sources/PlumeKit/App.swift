import AppKit
import Foundation

// Forked from digimata/quill (MIT). Quill ran as a bare LaunchAgent binary with its
// Info.plist linked into the __TEXT section so TCC could attribute permissions to it.
// Plume is a real .app instead: Spike A measured that a shell-launched binary captures
// full-length digital silence, while a bundle launched via LaunchServices gets its own
// TCC identity and captures normally. See spikes/responsible-process/RESULTS.md.
//
// That also removes the ArgumentParser dependency — an app doesn't need subcommands.
// `doctor` survives as an argument because it's genuinely useful when something breaks.

/// Entry point. Lives in the library so everything below it stays testable with
/// `@testable import PlumeKit`; the executable target is a one-line shim.
public enum PlumeApp {
    @MainActor
    public static func run() {
        if CommandLine.arguments.dropFirst().contains("doctor") {
            runDoctorAndExit()
        }

        let app = NSApplication.shared
        // Menubar-only: no Dock icon, no windows by default. Matches LSUIElement
        // in Info.plist; both are needed.
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private static func runDoctorAndExit() -> Never {
        let checks = DoctorReport.run(recordingsRoot: Config.resolveRoot(cliOverride: nil))
        DoctorReport.print(checks)
        FileHandle.standardError.write(Data("""

            note: system-audio capture cannot be verified from a terminal. TCC attributes
            the request to the responsible process — the terminal — so a tap created here
            records silence with no error. Only the bundled app can test it for real.

            """.utf8))
        exit(DoctorReport.allOK(checks) ? 0 : 1)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = Config.resolveRoot(cliOverride: nil)

        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            DoctorReport.print(checks)
            let failed = checks.compactMap { check in
                if case .fail = check.status { return check.name } else { return nil }
            }.joined(separator: ", ")
            notifyUser(title: "Plume — startup checks failed", body: failed)
        }

        controller = AppController(root: root)
        FileHandle.standardError.write(Data("plume up · meetings → \(root.path)\n".utf8))
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stopSessionIfRecording()
    }
}

/// Owns the menu bar, the current recording session, and the elapsed-time
/// ticker. All state transitions happen on the main actor.
@MainActor
final class AppController {
    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private var session: RecordingSession?
    private var ticker: Timer?

    init(root: URL) {
        self.root = root
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.update(recording: false, elapsed: nil)

        Task { [transcription, root] in
            await transcription.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.showTranscription(status)
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    /// Stop any live session cleanly (finalizing files) and exit.
    func shutdown() {
        stopSessionIfRecording()
        NSApp.terminate(nil)
    }

    func stopSessionIfRecording() {
        guard session != nil else { return }
        stopSession()
    }

    private func toggle() {
        if session == nil {
            startSession()
        } else {
            stopSession()
        }
    }

    private func startSession() {
        do {
            let newSession = try RecordingSession(root: root)
            try newSession.start()
            session = newSession
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            notifyUser(title: "Plume — recording failed", body: "\(error)")
            return
        }

        menuBar.update(recording: true, elapsed: "0:00")
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopSession() {
        guard let session else { return }
        session.stop()
        let elapsed = Self.format(Date().timeIntervalSince(session.startedAt))
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        menuBar.update(recording: false, elapsed: nil)

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func showTranscription(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle:
            menuBar.updateTranscription(nil)
        case .transcribing(let name, let queued):
            menuBar.updateTranscription(
                queued > 0 ? "transcribing \(name) · \(queued) queued" : "transcribing \(name)"
            )
        case .failed(let name):
            menuBar.updateTranscription("transcription failed · \(name)")
        }
    }

    private func tick() {
        guard let session else { return }
        menuBar.update(
            recording: true,
            elapsed: Self.format(Date().timeIntervalSince(session.startedAt))
        )
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
