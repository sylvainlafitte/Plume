import SwiftUI

/// Window controls, top-left, in macOS order: close then minimise.
///
/// Custom rather than real traffic lights — those need a visible titlebar, and
/// changing the style mask afterwards is the AppKit trap Spike B found, where
/// typing silently stops working. Same position and same order, so the mental
/// model carries over.
private struct PanelControls: View {
    let onClose: () -> Void
    let onCollapse: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close the panel (⌘W) — reopen from the menu bar")
            .keyboardShortcut("w", modifiers: .command)

            Button(action: onCollapse) {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Collapse to a small pill (⌘M)")
            .keyboardShortcut("m", modifiers: .command)
        }
        .font(.system(size: 12))
    }
}

/// Collapsed state: a small floating pill. Click to expand.
///
/// Reads `controller` directly rather than taking values as parameters, so a
/// ticking clock updates only this label instead of rebuilding the whole tree —
/// which is what made it visibly flash once a second.
struct MeetingPillView: View {
    let controller: MeetingPanelController

    var body: some View {
        Button {
            controller.expand()
        } label: {
            HStack(spacing: 4) {
                if controller.isRecording {
                    Circle().fill(.red).frame(width: 5, height: 5)
                    Text(controller.elapsed)
                        .font(.system(size: 10, design: .monospaced))
                        .monospacedDigit()
                        .fixedSize()
                } else {
                    Image(systemName: "text.append").font(.system(size: 9))
                }
            }
            // Fill the window exactly. Without this the label's intrinsic height
            // exceeded the frame and the material was clipped square at the
            // bottom, so it read as a cut-off rectangle rather than a pill.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: Capsule())
        .clipShape(Capsule())
        .help("Click to expand Plume")
    }
}

/// Live notes during the call — a full editing surface, not a commit field.
struct RecordingStripView: View {
    @Bindable var controller: MeetingPanelController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PanelControls(
                    onClose: { controller.close() },
                    onCollapse: { controller.collapse() })
                Spacer()
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(controller.elapsed)
                    .font(.system(.body, design: .monospaced)).monospacedDigit().bold()
                Button("Stop") { controller.requestStop() }
            }

            TextEditor(text: $controller.notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Button {
                    controller.insertStamp()
                } label: {
                    Label("Timestamp", systemImage: "clock")
                        .labelStyle(.titleAndIcon).font(.caption)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("t", modifiers: .command)
                .help("Insert the current time (⌘T) — for notes tied to a moment")
                Spacer()
                Text("Saved as you type").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial)
    }
}

/// After the call: notes, then the summary they produce.
struct WrapUpView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case summary = "Summary"
        var id: String { rawValue }
    }

    @Bindable var controller: MeetingPanelController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                PanelControls(
                    onClose: { controller.close() },
                    onCollapse: { controller.collapse() })
                Text(controller.title).font(.headline).lineLimit(1)
                Spacer()
                Button("Open") { controller.openInEditor() }
                    .help("Open meeting.md in your markdown editor")
            }

            Picker("", selection: $controller.tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch controller.tab {
            case .notes: notesTab
            case .summary: summaryTab
            }

            if let error = controller.error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
        .padding(14)
        .background(.regularMaterial)
    }

    private var notesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $controller.notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text("These are yours — nothing rewrites them.")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()

            // The primary action lives here, not on the Summary tab: notes are
            // the input and the summary is the output, so the button belongs
            // where you finish working — and editing then regenerating never
            // requires bouncing between tabs.
            HStack(spacing: 8) {
                Picker("", selection: $controller.templateID) {
                    ForEach(controller.templates, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()

                if controller.isGenerating {
                    ProgressView().controlSize(.small)
                } else if !controller.transcriptReady {
                    Text("transcribing…").font(.caption2).foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Button(controller.summary.isEmpty ? "Summarize" : "Regenerate") {
                    controller.summarize()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!controller.transcriptReady || controller.isGenerating)
            }
        }
    }

    private var summaryTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Generating with nothing streamed yet: the model is loading, which
            // on a cold start is many seconds. An empty pane reads as failure.
            if controller.isGenerating && controller.summary.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(controller.progressNote)
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView {
                if !controller.summary.isEmpty {
                    Text(controller.summary)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else if !controller.isGenerating {
                    Text("No summary yet — write your notes, then press Summarize.")
                        .font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity)

            if controller.isGenerating && !controller.summary.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(controller.progressNote).font(.caption2).foregroundStyle(.secondary)
                }
            }

            if !controller.speakerRows.isEmpty {
                Divider()
                SpeakerListView(
                    rows: controller.speakerRows,
                    onRename: { controller.rename($0, to: $1) },
                    onMerge: { controller.merge($0, into: $1) })
            }
        }
    }
}

/// One speaker label, with a proposed name if the transcript supported one.
struct SpeakerRow: Identifiable, Equatable {
    var id: String { label }
    let label: String
    /// Representative lines, so a voice can be identified without reading the
    /// whole transcript — which the app deliberately never shows.
    let samples: [String]
    let proposal: SpeakerProposal?
}

/// Rename, merge, and accept-a-proposal.
///
/// Merge is not optional polish: diarization's characteristic failure is
/// splitting one person across two labels, and renaming alone cannot repair it.
struct SpeakerListView: View {
    let rows: [SpeakerRow]
    let onRename: (String, String) -> Void
    let onMerge: (String, String) -> Void

    @State private var drafts: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speakers").font(.caption).foregroundStyle(.secondary)

            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(row.label)
                            .font(.system(.caption, design: .monospaced))
                            .frame(width: 28, alignment: .leading)

                        TextField(
                            row.proposal?.name ?? "name",
                            text: Binding(
                                get: { drafts[row.label] ?? "" },
                                set: { drafts[row.label] = $0 })
                        )
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            let name = (drafts[row.label] ?? "")
                                .trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty { onRename(row.label, name) }
                        }

                        if rows.count > 1 {
                            Menu {
                                ForEach(rows.filter { $0.label != row.label }) { other in
                                    Button("Merge into \(other.label)") {
                                        onMerge(row.label, other.label)
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.triangle.merge")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Same person split in two? Merge them.")
                        }
                    }

                    if let proposal = row.proposal {
                        // Evidence is shown, never hidden behind the name: this
                        // is a suggestion being accepted, not a fact.
                        Button {
                            drafts[row.label] = proposal.name
                            onRename(row.label, proposal.name)
                        } label: {
                            Text("Use “\(proposal.name)” — \(proposal.evidence)")
                                .font(.caption2)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.link)
                    } else if let sample = row.samples.first {
                        Text("“\(sample)”")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }
}
