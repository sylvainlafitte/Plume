import AppKit
import SwiftUI

/// Settings live in `~/.config/plume/config.json`; this window is a view onto
/// that file, not a second store. Only options that genuinely need UI belong
/// here — a folder picker, a toggle whose consequence isn't obvious, a login
/// item. Everything else stays hand-editable and undocumented in the UI.
///
/// Panes accrete per phase (docs/PLAN.md F10): Phase 4 adds the Ollama model
/// picker, Phase 5 the panel hotkey. Building the shell now avoids a late
/// scramble to rediscover eleven scattered options.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    /// Set by AppController; the probes live there because they need the app's
    /// own TCC identity.
    var onRunDiagnostics: (() -> Void)?

    func show() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView(onRunDiagnostics: { [weak self] in
                    self?.onRunDiagnostics?()
                }))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Plume Settings"
            window.styleMask = [.titled, .closable]
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
    let onRunDiagnostics: () -> Void
    @State private var settings = Config.current()
    @State private var saveError: String?
    @State private var installedModels: [String] = []
    @State private var modelsError: String?
    private var templates: [SummaryTemplate] { TemplateStore.all() }

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
            } header: {
                Text("Summaries")
            } footer: {
                if let modelsError {
                    Text(modelsError).font(.caption).foregroundStyle(.orange)
                } else {
                    Text(
                        "Summaries run locally through Ollama. Templates are plain markdown "
                        + "files — the text in them is the instruction sent to the model, so "
                        + "you can edit or add your own."
                    ).font(.caption).foregroundStyle(.secondary)
                }
            }

            if let saveError {
                Section {
                    Text(saveError).foregroundStyle(.red).font(.caption)
                }
            }

            Section {
                LabeledContent("Diagnostics") {
                    Button("Run checks…", action: onRunDiagnostics)
                }
                LabeledContent("Config file") {
                    Button("Reveal in Finder", action: revealConfig)
                }
            } footer: {
                Text(
                    "Checks record and play a short tone to verify capture actually works — "
                    + "every other signal looks healthy even when it doesn't.\n\n"
                    + "Settings are stored in \(Config.path.path) and can be edited by hand."
                ).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .task {
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
