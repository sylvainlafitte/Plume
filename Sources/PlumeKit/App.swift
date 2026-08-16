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
        // Dev tool: report the login-item state. Only meaningful when run as
        // `/Applications/Plume.app/Contents/MacOS/plume loginitem` — SMAppService
        // keys on the *calling* bundle, so a bare binary always says notFound.
        if args.contains("loginitem") {
            print("bundle: \(Bundle.main.bundleIdentifier ?? "none") @ \(Bundle.main.bundlePath)")
            print("state:  \(LoginItem.state)")
            if args.contains("register") { print("register → \(LoginItem.set(true))") }
            if args.contains("unregister") { print("unregister → \(LoginItem.set(false))") }
            exit(0)
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

        // Standard editing commands (⌘C/⌘V/⌘X/⌘A/⌘Z) route through the main
        // menu's key equivalents even for a menubar-only app with no visible
        // menu bar. Without this they beep.
        AppMenu.install()

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

        let controller = AppController()
        self.controller = controller

        let checks = DoctorReport.run(recordingsRoot: root)
        if !DoctorReport.allOK(checks) {
            DoctorReport.print(checks)
            let failed = checks.compactMap { check in
                if case .fail = check.status { return check.name } else { return nil }
            }.joined(separator: ", ")
            // Into AppState rather than only a notification: a banner is missed
            // if the user is away, and then nothing on screen says anything is wrong.
            Log.write("startup checks failed · \(failed)")
            controller.state.report("startup checks failed · \(failed)")
            notifyUser(title: "Plume — startup checks failed", body: failed)
        }

        // R8: reclaim scratch files a crashed diarization left behind. Cheap,
        // and nothing else ever notices them.
        let swept = TempSweep.run()
        if !swept.isEmpty {
            Log.write("swept \(swept.count) abandoned temp file(s)")
        }

        // First run, or a cache someone cleared: show setup rather than letting
        // the first meeting discover it. R7 — the download used to happen lazily
        // inside the first transcription, i.e. after a real meeting, with no
        // progress and no way to tell slow from broken.
        if SetupWindowController.isNeeded {
            controller.showSetup()
        }

        Log.write("plume up · meetings → \(root.path)")
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

    /// Re-read on every use, never captured at launch: the meetings folder is
    /// a setting, and a stored copy meant new recordings kept landing in the
    /// folder that was configured when the app started. `Config` is
    /// mtime-cached, so this is cheap.
    private var root: URL { Config.resolveRoot(cliOverride: nil) }
    private let menuBar = MenuBarController()
    private let transcription = TranscriptionCoordinator()
    private let settingsWindow = SettingsWindowController()
    private let setupWindow = SetupWindowController()
    private let hotkey = GlobalHotkey()
    private var cameraWatch: CameraWatch?
    private var notifications: NotificationRouter?
    private let meetingPanel = MeetingPanelController()
    private let historyWindow: HistoryWindowController
    private var session: RecordingSession?
    private var ticker: Timer?

    init() {
        historyWindow = HistoryWindowController()
        menuBar.onToggle = { [weak self] in self?.toggle() }
        menuBar.onQuit = { [weak self] in self?.shutdown() }
        menuBar.onDismissFailure = { [weak self] in self?.state.clearFailure() }
        menuBar.onOpenSettings = { [weak self] in
            self?.settingsWindow.onCallDetectionChanged = { [weak self] in
                self?.reloadCallDetection()
            }
            self?.settingsWindow.onOpenSetup = { [weak self] in self?.showSetup() }
            self?.settingsWindow.show()
        }
        menuBar.onOpenHistory = { [weak self] in self?.historyWindow.show() }
        menuBar.onOpenSetup = { [weak self] in self?.showSetup() }
        menuBar.onTogglePanel = { [weak self] in self?.meetingPanel.focus() }
        meetingPanel.onStopRequested = { [weak self] in self?.stopSessionIfRecording() }
        meetingPanel.onSessionFinished = { [weak self] in
            guard let self else { return }
            self.state.hasPanelSession = self.meetingPanel.hasSession
        }

        // ⌥⌘R from anywhere. Carbon, so it needs no Accessibility grant — see
        // GlobalHotkey. A refusal means another app owns the combination; the
        // menu bar item still works, so this is a note, not a failure.
        if !hotkey.register(onFire: { [weak self] in self?.toggle() }) {
            Log.write("⌥⌘R is taken by another app — hotkey disabled")
        }

        // Set before anything can be posted, or a click on the first
        // notification has nowhere to go.
        notifications = NotificationRouter(onStartRecording: { [weak self] in
            guard let self, !state.recording.isRecording else { return }
            startSession()
        })

        // Opt-in (`call_detection`), so this usually does nothing at all.
        let watch = CameraWatch(
            isRecording: { [weak self] in self?.state.recording.isRecording ?? false },
            onDetected: { [weak self] in self?.cameraTurnedOn() })
        watch.startIfEnabled()
        cameraWatch = watch

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

    /// The camera came on and we are not recording. Deliberately only a
    /// *notification* plus a menu-bar line: starting a recording from a guess
    /// about what the camera is doing would be the one unrecoverable mistake
    /// this feature could make.
    private func cameraTurnedOn() {
        state.callHint = true
        Log.write("camera turned on while idle — reminded the user")
        Notify.post(
            title: "Plume isn't recording",
            body: "Your camera just turned on. Click to start recording, or press ⌥⌘R.",
            category: .callDetected)
    }

    /// Settings changed while running — re-read rather than requiring a restart.
    func reloadCallDetection() { cameraWatch?.startIfEnabled() }

    /// Surfaced so `applicationDidFinishLaunching` can open setup without
    /// reaching into the controller's windows.
    func showSetup() { setupWindow.show(root: root) }

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
            // The reminder did its job (or was irrelevant): stop showing it.
            state.callHint = false
            state.clearFailure()
            meetingPanel.startedRecording(session: newSession.dir, at: newSession.startedAt)
            state.hasPanelSession = true
            Log.write("● recording → \(newSession.dir.path)")
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
                self.meetingPanel.tick()
            }
        }
    }

    private func stopSession() {
        guard let session else { return }
        session.stop()
        let elapsed = state.elapsedText ?? "0:00"
        Log.write("○ stopped · \(elapsed) · \(session.dir.path)")
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        state.recording = .idle
        // The panel stays up and expands: the meeting isn't over for the user
        // just because the recording is (docs/PLAN.md F8).
        meetingPanel.stoppedRecording()

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }




}
