import AppKit
import Foundation

// Forked from digimata/quill (MIT). Quill ran as a bare LaunchAgent binary with its
// Info.plist linked into the __TEXT section so TCC could attribute permissions to it.
// Plume is a real .app instead: a bare binary has no TCC identity of its own and
// inherits whatever the responsible process happens to hold, which for a shell is the
// terminal — so capture may silently record nothing, or work for reasons unrelated to
// the app. A bundle gets a deterministic, self-owned grant and its own prompt.
// See spikes/responsible-process/RESULTS.md.
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
        let checks = DoctorReport.run(
            recordingsRoot: Config.resolveRoot(cliOverride: nil), probeAudio: true)
        DoctorReport.print(checks)
        FileHandle.standardError.write(Data("""

            note: the "system audio" result here is inconclusive in both directions. A bare
            binary has no TCC identity of its own — capture is attributed to the responsible
            process, i.e. your terminal. A pass means your terminal has permission; a failure
            means it doesn't. Neither says anything about Plume.app. Use "Run diagnostics…"
            from Plume's menu bar. See spikes/responsible-process/RESULTS.md.

            """.utf8))
        exit(DoctorReport.allOK(checks) ? 0 : 1)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let root = Config.resolveRoot(cliOverride: nil)

        let controller = AppController(root: root)
        self.controller = controller

        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            DoctorReport.print(checks)
            let failed = checks.compactMap { check in
                if case .fail = check.status { return check.name } else { return nil }
            }.joined(separator: ", ")
            // Into AppState rather than only a notification: a banner is missed
            // if the user is away, and then nothing on screen says anything is wrong.
            controller.state.report("startup checks failed · \(failed)")
            notifyUser(title: "Plume — startup checks failed", body: failed)
        }

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
    let state = AppState()

    private let root: URL
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private let settingsWindow = SettingsWindowController()
    private var session: RecordingSession?
    private var ticker: Timer?

    init(root: URL) {
        self.root = root
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onOpenFolder = { [weak self] in self?.openFolder() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.onDismissFailure = { [weak self] in self?.state.clearFailure() }
        menuBar.onRunDiagnostics = { [weak self] in self?.runDiagnostics() }
        menuBar.onOpenSettings = { [weak self] in self?.settingsWindow.show() }

        observeState()

        Task { [transcription, root, state] in
            await transcription.setStatusHandler { status in
                Task { @MainActor in
                    switch status {
                    case .idle: state.transcription = .idle
                    case .transcribing(let name, let queued):
                        state.transcription = .working(name: name, queued: queued)
                    case .failed(let name):
                        state.transcription = .failed(name: name)
                        state.report("transcription failed · \(name)")
                    }
                }
            }
            await transcription.resumePending(root: root)
        }
    }

    /// Re-render the menu bar whenever any observed property of `state`
    /// changes. `withObservationTracking` fires once per change, so it
    /// re-arms itself each time.
    private func observeState() {
        withObservationTracking {
            menuBar.render(state)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeState() }
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
            state.recording = .recording(since: newSession.startedAt)
            state.clearFailure()
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            state.report("recording failed to start: \(error)")
            notifyUser(title: "Plume — recording failed", body: "\(error)")
            return
        }

        // Drives the elapsed counter. `state.elapsedText` derives from the start
        // date, so the timer only needs to nudge observation, not carry a value.
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, case .recording(let since) = self.state.recording else { return }
                self.state.recording = .recording(since: since)
            }
        }
    }

    private func stopSession() {
        guard let session else { return }
        session.stop()
        let elapsed = state.elapsedText ?? "0:00"
        FileHandle.standardError.write(Data(
            "○ stopped · \(elapsed) · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        state.recording = .idle

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    /// Run the full checks including the ~2s empirical capture probes, then show
    /// the result. Off the main actor because the probes sleep while capturing.
    private func runDiagnostics() {
        let root = self.root
        Task.detached(priority: .userInitiated) {
            let checks = DoctorReport.run(recordingsRoot: root, probeAudio: true)
            await MainActor.run { [weak self] in
                self?.presentDiagnostics(checks)
            }
        }
    }

    private func presentDiagnostics(_ checks: [Check]) {
        let failures = checks.filter { if case .fail = $0.status { return true } else { return false } }
        let body = checks.map { check -> String in
            let mark: String
            switch check.status {
            case .ok: mark = "✅"
            case .warn: mark = "⚠️"
            case .fail: mark = "❌"
            }
            var line = "\(mark)  \(check.name)"
            switch check.status {
            case .ok: break
            case .warn(let detail), .fail(let detail): line += " — \(detail)"
            }
            if let remediation = check.remediation, !remediation.isEmpty,
                !check.status.isOK
            {
                line += "\n      \(remediation)"
            }
            return line
        }.joined(separator: "\n")

        if let first = failures.first, case .fail(let detail) = first.status {
            state.report("\(first.name): \(detail)")
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = failures.isEmpty ? "Plume diagnostics passed" : "Plume diagnostics found problems"
        alert.informativeText = body
        alert.alertStyle = failures.isEmpty ? .informational : .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func openFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

}
