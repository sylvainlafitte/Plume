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

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView())
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
    @State private var settings = Config.current()
    @State private var saveError: String?

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
                Toggle(
                    "Echo cancellation on the microphone",
                    isOn: Binding(
                        get: { settings.micVoiceProcessing ?? false },
                        set: { newValue in
                            settings.micVoiceProcessing = newValue
                            save { $0.micVoiceProcessing = newValue }
                        }
                    )
                )
            } footer: {
                // The trade-off is non-obvious and costs a meeting if wrong, so
                // it is stated rather than left to the toggle's name.
                Text(
                    "Off by default. On headphones there is no echo to cancel, and enabling it "
                    + "makes macOS treat the session as a call and quieten other audio. Turn it "
                    + "on when meetings play through speakers."
                )
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

                Toggle(
                    "Remove echo of the other side from my track",
                    isOn: Binding(
                        get: { settings.transcriptEchoFilter ?? true },
                        set: { newValue in
                            settings.transcriptEchoFilter = newValue
                            save { $0.transcriptEchoFilter = newValue }
                        }
                    )
                )
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
                    + "can merge afterwards.\n\n"
                    + "Echo removal matters when meetings play through speakers — your mic hears "
                    + "them and every sentence would otherwise appear twice."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(
                    "Transcribe recordings automatically",
                    isOn: Binding(
                        get: { settings.transcription?.enabled ?? true },
                        set: { newValue in
                            save { $0.transcription = Settings.Transcription(
                                enabled: newValue, engine: $0.transcription?.engine) }
                            settings = Config.current()
                        }
                    )
                )
            }

            if let saveError {
                Section {
                    Text(saveError).foregroundStyle(.red).font(.caption)
                }
            }

            Section {
                LabeledContent("Config file") {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Config.path])
                    }
                }
            } footer: {
                Text("Everything here is stored in \(Config.path.path) and can be edited by hand.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
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

    private func save(_ mutate: @escaping (inout Settings) -> Void) {
        do {
            try Config.update(mutate)
            saveError = nil
        } catch {
            saveError = "Couldn't save settings: \(error.localizedDescription)"
        }
    }
}
