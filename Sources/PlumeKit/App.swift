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
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("doctor") {
            runDoctorAndExit()
        }
        // Dev tool, not a product feature: diarize a file and print the turns.
        // This is the tuning loop for the held-aside test corpus (docs/PLAN.md
        // R3) — production audio is deleted, so config changes can only be
        // evaluated against kept recordings.
        if let index = args.firstIndex(of: "diarize"), index + 1 < args.count {
            runDiarizeAndExit(path: args[index + 1])
        }
        // Dev tool: summarize a session folder in place. Phase 5 moves the
        // trigger into the wrap-up panel; this keeps it verifiable meanwhile.
        if let index = args.firstIndex(of: "summarize"), index + 1 < args.count {
            let template = args.firstIndex(of: "--template").flatMap {
                $0 + 1 < args.count ? args[$0 + 1] : nil
            }
            runSummarizeAndExit(path: args[index + 1], templateID: template)
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

    private static func runSummarizeAndExit(path: String, templateID: String?) -> Never {
        let session = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let template = templateID.flatMap { TemplateStore.template(id: $0) }
            ?? TemplateStore.default()
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var code: Int32 = 0

        Task.detached {
            do {
                Swift.print("session : \(session.lastPathComponent)")
                Swift.print("template: \(template.name) (\(template.id))")
                Swift.print("model   : \(Config.summaryModel()) @ num_ctx \(Config.summaryContextTokens())\n")

                nonisolated(unsafe) var lastWindow = -1
                let started = Date()
                try await SummaryEngine().summarize(session: session, template: template) {
                    progress in
                    if progress.windowsTotal > 1, progress.windowsDone != lastWindow {
                        lastWindow = progress.windowsDone
                        FileHandle.standardError.write(Data(
                            "  window \(progress.windowsDone + 1)/\(progress.windowsTotal)…\n".utf8))
                    }
                }
                Swift.print(String(
                    format: "done in %.1fs — summary written to meeting.md",
                    Date().timeIntervalSince(started)))
            } catch {
                FileHandle.standardError.write(Data("summarize failed: \(error)\n".utf8))
                code = 1
            }
            done.signal()
        }
        done.wait()
        exit(code)
    }

    private static func runDiarizeAndExit(path: String) -> Never {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var code: Int32 = 0

        Task.detached {
            let diarizer = OfflineDiarizer(maxSpeakers: Config.maxFarEndSpeakers())
            do {
                let started = Date()
                try await diarizer.prepare()
                let loaded = Date()
                let turns = try await diarizer.diarize(url)
                let finished = Date()

                let speakers = Set(turns.map(\.speakerId)).sorted()
                Swift.print("file      : \(url.lastPathComponent)")
                Swift.print("engine    : \(diarizer.name)")
                Swift.print(String(
                    format: "model load: %.1fs   diarize: %.1fs",
                    loaded.timeIntervalSince(started), finished.timeIntervalSince(loaded)))
                Swift.print("speakers  : \(speakers.count) — \(speakers.joined(separator: ", "))")
                Swift.print("turns     : \(turns.count)\n")
                for turn in turns {
                    Swift.print(String(
                        format: "  %-4@ %7.2f → %7.2f  (%5.2fs, q=%.2f)",
                        turn.speakerId as NSString, turn.start, turn.end,
                        turn.end - turn.start, turn.quality))
                }
            } catch {
                FileHandle.standardError.write(Data("diarization failed: \(error)\n".utf8))
                code = 1
            }
            done.signal()
        }
        done.wait()
        exit(code)
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
            var checks = DoctorReport.run(recordingsRoot: root, probeAudio: true)
            checks.append(await DoctorReport.checkSummarization())
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
