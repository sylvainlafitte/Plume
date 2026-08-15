import SwiftUI

/// Live strip. Deliberately small: it sits over a video call for the whole
/// meeting, so it shows elapsed time, a stop button, and somewhere to type.
struct RecordingStripView: View {
    let elapsed: String
    let onNote: (String) -> Void
    let onStop: () -> Void
    let onHide: () -> Void

    @State private var draft = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(elapsed).font(.system(.body, design: .monospaced)).bold()
                Spacer()
                Button("Stop", action: onStop)
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button {
                    onHide()
                } label: {
                    Image(systemName: "eye.slash")
                }
                .buttonStyle(.borderless)
                .help("Hide the panel (⌘⇧H). It is excluded from screen sharing, "
                    + "but treat that as best-effort.")
            }

            TextField("Note…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .focused($noteFocused)
                .onSubmit(commit)

            Text("↩ saves a note with a timestamp")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial)
    }

    private func commit() {
        let text = draft
        draft = ""
        onNote(text)
        // Stay focused: notes come in bursts, and re-clicking mid-meeting is
        // exactly the friction this panel exists to avoid.
        noteFocused = true
    }
}

/// After the call: notes and summary side by side, with the speaker proposals
/// that need a human decision.
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

    let onSaveNotes: () -> Void
    let onSummarize: () -> Void
    let onOpenInEditor: () -> Void
    let onRename: (String, String) -> Void
    let onMerge: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                Button("Open", action: onOpenInEditor)
                    .help("Open meeting.md in your markdown editor")
            }

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .notes:
                notesTab
            case .summary:
                summaryTab
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(.regularMaterial)
    }

    private var notesTab: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Editable, not append-only: "add last thoughts before summarising"
            // means tidying what's there too.
            TextEditor(text: $notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: notes) { _, _ in onSaveNotes() }
            Text("Saved as you type. These are yours — nothing rewrites them.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var summaryTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !transcriptReady {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…").font(.callout).foregroundStyle(.secondary)
                }
                Text("You can keep adding notes while this finishes.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            HStack {
                Picker("Template", selection: $templateID) {
                    ForEach(templates, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 160)

                Button(summary.isEmpty ? "Summarize" : "Regenerate", action: onSummarize)
                    .disabled(!transcriptReady || isGenerating)
                if isGenerating { ProgressView().controlSize(.small) }
            }

            ScrollView {
                Text(summary.isEmpty ? "No summary yet." : summary)
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
    @State private var mergeSource: String?

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
                            let name = (drafts[row.label] ?? "").trimmingCharacters(
                                in: .whitespaces)
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
                        // is a suggestion the user is accepting, not a fact.
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
