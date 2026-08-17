import AppKit
import SwiftUI

/// Settings live in `~/.config/plume/config.json`; this window is a view onto
/// that file, not a second store. Only options that genuinely need UI belong
/// here — a folder picker, a toggle whose consequence isn't obvious, a login
/// item. Everything else stays hand-editable and undocumented in the UI.
///
/// Panes accrete as features land. Today: meetings folder, meeting size, echo
/// handling, starting a recording (camera reminder, login item, and the ⌥⌘R
/// hotkey — stated, not editable), summaries, and troubleshooting. Readiness is
/// deliberately *not* here: Setup & Checks owns every "is Plume ready" question,
/// and this window links to it (AGENTS.md §2).
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    var onCallDetectionChanged: (() -> Void)?
    var onOpenSetup: (() -> Void)?
    var onUpdateCheckChanged: (() -> Void)?

    func show() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(
                    onCallDetectionChanged: { [weak self] in self?.onCallDetectionChanged?() },
                    onOpenSetup: { [weak self] in self?.onOpenSetup?() },
                    onUpdateCheckChanged: { [weak self] in self?.onUpdateCheckChanged?() }))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Plume Settings"
            // Resizable, because the content is now taller than some screens
            // and a settings window you cannot shrink is a settings window with
            // buttons off the bottom edge.
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // An .accessory app has no menu bar of its own, so activate explicitly
        // or the window opens behind whatever is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    /// So a toggle takes effect now rather than at the next launch.
    var onCallDetectionChanged: () -> Void = {}
    var onOpenSetup: () -> Void = {}
    var onUpdateCheckChanged: () -> Void = {}
    @State private var settings = Config.current()
    @State private var saveError: String?
    @State private var installedModels: [String] = []
    @State private var loginItem = LoginItem.state
    /// Re-read when the window appears, so downloading models in the setup
    /// window is reflected here without a relaunch.
    @State private var modelsReady = ModelSetup.allReady
    @State private var modelsError: String?
    private var templates: [SummaryTemplate] { TemplateStore.all() }

    /// `requiresApproval` means the user turned it off in System Settings.
    /// Re-enabling from here would be overruling them, so the control is
    /// disabled and says where the decision lives.
    private var isLoginItemBlocked: Bool { loginItem == .blockedByUser }

    var body: some View {
        Form {
            Section {
                LabeledContent("Meetings folder") {
                    HStack {
                        Text(Config.resolveRoot(cliOverride: nil).path)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
            } footer: {
                Text("Recordings, transcripts and summaries are written here.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker(
                    "Usual meeting size",
                    selection: Binding(
                        get: { settings.expectedParticipants ?? 2 },
                        set: { newValue in
                            save { $0.expectedParticipants = newValue }
                            settings = Config.current()
                        }
                    )
                ) {
                    Text("1:1 — two people").tag(2)
                    Text("Three people").tag(3)
                    Text("Four people").tag(4)
                    Text("Five people").tag(5)
                    Text("Let Plume decide — larger or varied meetings").tag(0)
                    // This window advertises the config file as hand-editable, so
                    // a value outside the presets must not blank the picker.
                    if let custom = settings.expectedParticipants,
                        ![0, 2, 3, 4, 5].contains(custom)
                    {
                        Text("\(custom) people (from config file)").tag(custom)
                    }
                }

            } header: {
                Text("Transcript")
            } footer: {
                // Says what it does to the transcript, not what it does to the
                // clusterer — the number is a hint, and the consequence of
                // getting it wrong is what the user needs to weigh.
                Text(
                    "Your microphone is always kept separate, so this only tells Plume how many "
                    + "other voices to expect. Guessing too low merges people together; "
                    + "\"Let Plume decide\" can occasionally split one person in two, which you "
                    + "can merge afterwards."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            // Two settings, because there are two chances to catch the same
            // problem and they are not interchangeable: one edits the audio as
            // it is captured, the other edits the finished transcript. Kept
            // together so the weaker, always-safe one is chosen first.
            Section {
                Toggle(
                    "Drop echoed sentences from the transcript",
                    isOn: Binding(
                        get: { settings.transcriptEchoFilter ?? true },
                        set: { newValue in
                            settings.transcriptEchoFilter = newValue
                            save { $0.transcriptEchoFilter = newValue }
                        }
                    )
                )
                Toggle(
                    "Also cancel echo at the microphone while recording",
                    isOn: Binding(
                        get: { settings.micVoiceProcessing ?? false },
                        set: { newValue in
                            settings.micVoiceProcessing = newValue
                            save { $0.micVoiceProcessing = newValue }
                        }
                    )
                )
            } header: {
                Text("Echo from speakers")
            } footer: {
                // The second toggle's cost is non-obvious and is paid on every
                // recording, so it is stated rather than left to its name.
                Text(
                    "When a meeting plays through speakers your microphone hears the other side "
                    + "too, so every sentence risks appearing twice.\n\n"
                    + "The first setting is the safe one: it compares the two tracks afterwards "
                    + "and removes the duplicates, changing nothing about the recording. Leave "
                    + "it on — on headphones there is nothing to remove.\n\n"
                    + "The second stops the echo being recorded at all, but macOS then treats "
                    + "the session as a call and quietens other audio for the whole meeting. "
                    + "Turn it on only if duplicates still get through."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    "Remind me when my camera turns on",
                    isOn: Binding(
                        get: { settings.callDetection ?? false },
                        set: { newValue in
                            settings.callDetection = newValue
                            save { $0.callDetection = newValue }
                            onCallDetectionChanged()
                        }
                    )
                )
                Toggle(
                    "Open Plume at login",
                    isOn: Binding(
                        get: { loginItem == .enabled },
                        set: { loginItem = LoginItem.set($0) }
                    )
                )
                .disabled(isLoginItemBlocked)
            } header: {
                Text("Starting a recording")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    // The limits are stated because both are surprising: it
                    // never records for you, and it cannot see audio-only calls.
                    Text(
                        "Plume can notice your camera switching on — usually the moment a "
                        + "video call starts — and remind you it isn't recording. It never "
                        + "starts a recording by itself, and it can't tell which app is using "
                        + "the camera. Audio-only calls go unnoticed."
                    )
                    if case .unavailable(let why) = loginItem {
                        Text("Login item unavailable: \(why)")
                            .foregroundStyle(.orange)
                    } else if isLoginItemBlocked {
                        Text("Login item blocked in System Settings ▸ General ▸ Login Items.")
                            .foregroundStyle(.orange)
                    }
                    Text("⌥⌘R starts and stops a recording from any app.")
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker(
                    "Summary model",
                    selection: Binding(
                        get: { settings.summaryModel ?? Config.summaryModel() },
                        set: { newValue in
                            save { $0.summaryModel = newValue }
                            settings = Config.current()
                        }
                    )
                ) {
                    ForEach(installedModels, id: \.self) { Text($0).tag($0) }
                    // Keep the configured model selectable even if Ollama is
                    // down or the model was removed — otherwise opening Settings
                    // while offline would silently reset it.
                    let current = settings.summaryModel ?? Config.summaryModel()
                    if !installedModels.contains(current) {
                        Text("\(current) (not installed)").tag(current)
                    }
                }
                .disabled(installedModels.isEmpty && modelsError == nil)

                Picker(
                    "Default template",
                    selection: Binding(
                        get: { settings.defaultTemplate ?? Config.defaultTemplate() },
                        set: { newValue in
                            save { $0.defaultTemplate = newValue }
                            settings = Config.current()
                        }
                    )
                ) {
                    ForEach(templates, id: \.id) { Text($0.name).tag($0.id) }
                }

                LabeledContent("Templates") {
                    Button("Open Templates Folder") {
                        try? TemplateStore.seedIfNeeded()
                        NSWorkspace.shared.open(TemplateStore.directory)
                    }
                }

                LabeledContent("Vocabulary") {
                    Button("Open Vocabulary File") {
                        // Seed first: opening a path that does not exist yet
                        // silently does nothing, which reads as a broken button.
                        try? VocabularyStore.seedIfNeeded()
                        NSWorkspace.shared.open(VocabularyStore.url)
                    }
                }
            } header: {
                Text("Summaries")
            } footer: {
                if let modelsError {
                    Text(modelsError).font(.caption).foregroundStyle(.orange)
                } else {
                    Text(
                        "Summaries run locally through Ollama. Templates are plain markdown "
                        + "files — the text in them is the instruction sent to the model, so "
                        + "you can edit or add your own. The vocabulary file lists names, "
                        + "products and jargon so summaries spell them correctly; it cannot "
                        + "correct the transcript, which is written before it is read."
                    ).font(.caption).foregroundStyle(.secondary)
                }
            }

            // Its own section rather than a row under Troubleshooting: the footer
            // has to state what leaves the machine, which is not a troubleshooting
            // concern and is the one claim in the README this feature can falsify.
            Section {
                LabeledContent("This version") {
                    Text(UpdateCheck.currentVersion).foregroundStyle(.secondary)
                }
                Toggle(
                    "Check for updates automatically",
                    isOn: Binding(
                        get: { settings.updateCheck ?? true },
                        set: { newValue in
                            settings.updateCheck = newValue
                            save { $0.updateCheck = newValue }
                            onUpdateCheckChanged()
                        }
                    )
                )
            } header: {
                Text("Updates")
            } footer: {
                Text(
                    "Plume is not in the App Store, so nothing else will tell you a new version "
                    + "exists. Once a day it asks GitHub for the latest release number and shows "
                    + "a line in the menu bar if yours is older. It sends no identifier and never "
                    + "installs anything by itself — the line opens the release page.\n\n"
                    + "Turned off, Plume makes no request at all."
                ).font(.caption).foregroundStyle(.secondary)
            }

            if let saveError {
                Section {
                    Text(saveError).foregroundStyle(.red).font(.caption)
                }
            }

            Section {
                // One row, because there is now one window behind it: setup and
                // the checks were the same six questions asked twice.
                LabeledContent("Setup & checks") {
                    HStack(spacing: 8) {
                        Text(modelsReady ? "Models installed" : "Models missing")
                            .foregroundStyle(modelsReady ? Color.green : Color.orange)
                        Button("Open…") { onOpenSetup() }
                    }
                }
                LabeledContent("Log") {
                    HStack(spacing: 8) {
                        Button("Open", action: openLog)
                        Button("Reveal in Finder", action: revealLog)
                    }
                }
                LabeledContent("Config file") {
                    Button("Reveal in Finder", action: revealConfig)
                }
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text(
                    "Setup & checks reports everything Plume needs — permissions, on-device "
                    + "models, Ollama, the meetings folder — and offers the fix beside "
                    + "anything that isn't ready. Its capture checks play a short tone and "
                    + "record, because every other signal looks healthy even when audio "
                    + "isn't working.\n\n"
                    + "The log is a plain text file at \(Log.file.path) — attach it to a bug "
                    + "report. Settings live in \(Config.path.path) and can be edited by hand."
                ).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Width fixed, height flexible. `fixedSize(vertical:)` was here, which
        // forces the window to the content's full natural height — fine when
        // there were three sections, and taller than the screen once there were
        // seven, with no scrollbar because nothing was ever clipped.
        .frame(width: 460)
        .frame(minHeight: 480, idealHeight: 900, maxHeight: .infinity)
        .task {
            modelsReady = ModelSetup.allReady
            do {
                installedModels = try await OllamaClient().tags()
                modelsError = installedModels.isEmpty
                    ? "No models installed — run `ollama pull gemma4`." : nil
            } catch {
                modelsError =
                    "Couldn't reach Ollama, so this list may be stale. "
                    + "Recording and transcription don't need it; summaries do."
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Config.resolveRoot(cliOverride: nil)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        save { $0.recordingsDir = url.path }
        settings = Config.current()
    }

    /// Reveal the config file, creating it first if it isn't there.
    ///
    /// Every setting has a code default and the file is only written when one
    /// is changed, so on a fresh install there is nothing to reveal — and
    /// `activateFileViewerSelecting` on a path that doesn't exist does nothing
    /// at all, with no error. Writing it first is harmless: every field is
    /// optional, so an untouched config encodes to `{}` and pins nothing.
    private func openLog() {
        // Create it if this is a quiet first run, so the button never appears
        // to do nothing.
        if !FileManager.default.fileExists(atPath: Log.file.path) {
            Log.write("log opened from Settings")
        }
        NSWorkspace.shared.open(Log.file)
    }

    private func revealLog() {
        if !FileManager.default.fileExists(atPath: Log.file.path) {
            Log.write("log revealed from Settings")
        }
        NSWorkspace.shared.activateFileViewerSelecting([Log.file])
    }

    private func revealConfig() {
        if !FileManager.default.fileExists(atPath: Config.path.path) {
            save { _ in }
        }
        NSWorkspace.shared.activateFileViewerSelecting([Config.path])
    }

    private func save(_ mutate: @escaping (inout Settings) -> Void) {
        do {
            try Config.update(mutate)
            saveError = nil
        } catch {
            saveError = "Couldn't save settings: \(error.localizedDescription)"
        }
    }
}
