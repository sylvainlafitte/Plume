import SwiftUI

/// Collapsed state: a small floating pill. Click to expand.
///
/// Exists because "hide entirely" was the wrong idiom — an eye-slash icon that
/// made the panel vanish with no obvious way back. A pill keeps a visible,
/// clickable handle while giving the screen back.
struct MeetingPillView: View {
    let isRecording: Bool
    let elapsed: String
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: 6) {
                if isRecording {
                    Circle().fill(.red).frame(width: 7, height: 7)
                    Text(elapsed).font(.system(.caption, design: .monospaced))
                } else {
                    Image(systemName: "text.append").font(.caption)
                    Text("Notes").font(.caption)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial)
        .help("Click to expand Plume")
    }
}

/// Small control shared by the expanded states.
private struct CollapseButton: View {
    let onCollapse: () -> Void
    var body: some View {
        Button(action: onCollapse) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Collapse to a small pill (⌘M)")
        .keyboardShortcut("m", modifiers: .command)
    }
}

/// Live notes during the call.
///
/// A full editing surface rather than a one-line commit field: notes are
/// written and *rewritten* as a meeting goes, and a field that only appends
/// forces you to get each line right first time.
struct RecordingStripView: View {
    let elapsed: String
    @Binding var notes: String
    let onStamp: () -> Void
    let onStop: () -> Void
    let onCollapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(elapsed).font(.system(.body, design: .monospaced)).bold()
                Spacer()
                Button("Stop", action: onStop)
                CollapseButton(onCollapse: onCollapse)
            }

            TextEditor(text: $notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Button {
                    onStamp()
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

    @Binding var tab: Tab
    @Binding var notes: String

    let title: String
    let transcriptReady: Bool
    let summary: String
    let isGenerating: Bool
    let templates: [SummaryTemplate]
    @Binding var templateID: String
    let speakers: [SpeakerRow]
    let error: String?

    let onSummarize: () -> Void
    let onOpenInEditor: () -> Void
    let onCollapse: () -> Void
    let onRename: (String, String) -> Void
    let onMerge: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                Button("Open", action: onOpenInEditor)
                    .help("Open meeting.md in your markdown editor")
                CollapseButton(onCollapse: onCollapse)
            }

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .notes: notesTab
            case .summary: summaryTab
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
        .padding(14)
        .background(.regularMaterial)
    }

    private var notesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            Text("These are yours — nothing rewrites them.")
                .font(.caption2).foregroundStyle(.secondary)

            Divider()

            // The primary action lives here, not on the Summary tab: notes are
            // the input and the summary is the output, so the button belongs
            // where you finish working. It also means editing notes and
            // regenerating never requires bouncing between tabs.
            HStack(spacing: 8) {
                Picker("", selection: $templateID) {
                    ForEach(templates, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 150)

                Button(summary.isEmpty ? "Summarize" : "Regenerate", action: onSummarize)
                    .buttonStyle(.borderedProminent)
                    .disabled(!transcriptReady || isGenerating)

                if isGenerating {
                    ProgressView().controlSize(.small)
                } else if !transcriptReady {
                    Text("transcribing…").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var summaryTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(summary.isEmpty
                    ? "No summary yet — write your notes, then press Summarize."
                    : summary)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .foregroundStyle(summary.isEmpty ? .secondary : .primary)
            }
            .frame(maxHeight: .infinity)

            if !speakers.isEmpty {
                Divider()
                SpeakerListView(rows: speakers, onRename: onRename, onMerge: onMerge)
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
