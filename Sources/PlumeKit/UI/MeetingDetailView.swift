import AppKit
import SwiftUI

/// Three views of one meeting: the input, the output, and interrogating it.
///
/// Phase 7's Ask becomes the third case. It was originally planned as a row
/// pinned under the summary (PLAN.md F11), on the grounds that a tab living only
/// in the post-call panel would be in the wrong place for old meetings. Sharing
/// this view between the panel and the history window dissolved that objection —
/// a tab now appears in both — and a tab is the better shape anyway: Ask is a
/// mode you stay in, not a control you poke once.
enum MeetingTab: String, CaseIterable, Identifiable {
    case notes = "Notes"
    case summary = "Summary"
    var id: String { rawValue }
}

/// What a meeting looks like to the UI, whether it finished two minutes ago or
/// two months ago.
///
/// Both the wrap-up panel and the history window present the same object — notes,
/// summary, speakers, and a regenerate action — so they share one view rather
/// than two implementations that merely resemble each other. They had already
/// started to drift (one rendered markdown, the other didn't) before this existed.
@MainActor
protocol MeetingDetailModel: AnyObject, Observable {
    var detailTab: MeetingTab { get set }
    /// Which tab this surface opens on. The panel is where you *write* a meeting
    /// record, so it starts on Notes; the history window is where you *read* one,
    /// so it starts on Summary. Fixed per surface, never per meeting — a default
    /// that changed with each selection would make the tab jump as you move down
    /// the list.
    var initialTab: MeetingTab { get }
    var notes: String { get set }
    var summary: String { get }
    var templateID: String { get set }
    var templates: [SummaryTemplate] { get }
    var speakerRows: [SpeakerRow] { get }
    var isGenerating: Bool { get }
    /// Shown beside the spinner: "Loading the model…", "part 2 of 4…".
    var progressNote: String { get }
    /// False while a transcript is still being produced.
    var canSummarize: Bool { get }
    /// Why summarizing is unavailable, if it is. Nil when it's available.
    var blockedReason: String? { get }
    var detailError: String? { get }

    func notesEdited()
    func summarize()
    func rename(_ label: String, to name: String)
    func merge(_ source: String, into destination: String)
}

/// Whether summarizing can work *before* you press the button.
///
/// An unreachable Ollama was previously only discovered afterwards, as a raw
/// error string — and a cold daemon is a normal first-run state (Ollama.app
/// starts it lazily), not a fault. Naming the model also answers "which one is
/// this about to use" without a trip to Settings.
private enum SummaryBackend: Equatable {
    case checking
    case ready(model: String)
    case missingModel(String)
    case unreachable

    var caption: String? {
        switch self {
        case .checking: nil
        case .ready(let model): model
        case .missingModel(let model): "\(model) not installed"
        case .unreachable: "Ollama isn't running"
        }
    }

    /// Only a real problem is worth colour; the model name is just context.
    var isProblem: Bool {
        switch self {
        case .checking, .ready: false
        case .missingModel, .unreachable: true
        }
    }
}

struct MeetingDetailView<Model: MeetingDetailModel>: View {
    @Bindable var model: Model
    @State private var backend: SummaryBackend = .checking

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $model.detailTab) {
                ForEach(MeetingTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch model.detailTab {
            case .notes: notesTab
            case .summary: summaryTab
            }

            if let error = model.detailError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            Divider()
            // Below the tabs, not inside one. Summarizing is an action on the
            // *meeting*, not on the notes — and pinning it here means the
            // default tab stops being load-bearing: whichever tab you land on,
            // the action is reachable. It also keeps the bottom edge free of
            // competing controls when Ask arrives as a third tab.
            summarizeBar
        }
        // Once per appearance, not per keystroke: this is a precondition check,
        // and the panel is opened far more often than Ollama changes state.
        .task { await checkBackend() }
    }

    private func checkBackend() async {
        let wanted = Config.summaryModel()
        guard let installed = try? await OllamaClient().tags() else {
            backend = .unreachable
            return
        }
        backend = installed.contains(wanted) ? .ready(model: wanted) : .missingModel(wanted)
    }

    private var notesTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $model.notes)
                .font(.body)
                .scrollContentBackground(.hidden)
                // Inside the background, so the inset is padding within the
                // field rather than a margin around it — a TextEditor otherwise
                // starts its text hard against the edge.
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: model.notes) { _, _ in model.notesEdited() }

            Text("These are yours — nothing rewrites them.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var summarizeBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $model.templateID) {
                ForEach(model.templates, id: \.id) { Text($0.name).tag($0.id) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()

            // Status sits against the button, not against the picker: it is
            // about the action, and a caption stranded mid-bar reads as a third
            // control rather than as a label for the one on its right.
            Spacer(minLength: 8)

            // Precedence: what's happening now, then what's blocking, then what
            // this would run against. Only one of the three is ever true.
            if model.isGenerating {
                ProgressView().controlSize(.small)
            } else if let reason = model.blockedReason {
                Text(reason).font(.caption2).foregroundStyle(.secondary)
            } else if let caption = backend.caption {
                Text(caption)
                    .font(.caption2)
                    // Orange was unreadable against the panel's grey. Red has
                    // the contrast, and these two states do block summarising.
                    // The model name is context, not information, so it drops
                    // to tertiary.
                    .foregroundStyle(backend.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Button(model.summary.isEmpty ? "Summarise" : "Regenerate") {
                model.summarize()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canSummarize || model.isGenerating)
        }
    }

    private func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.summary, forType: .string)
    }

    private var summaryTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Generating with nothing streamed yet: on a cold start the model
            // takes many seconds to load, and an empty pane reads as failure.
            if model.isGenerating && model.summary.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.progressNote).font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView {
                if !model.summary.isEmpty {
                    MarkdownText(markdown: model.summary)
                        // Drag-to-select is per-Text at best inside a rendered
                        // block layout, and unreliable in a non-activating panel.
                        // A copy action always works and is what you actually
                        // want for a summary headed into an email.
                        .contextMenu {
                            Button("Copy summary") { copySummary() }
                        }
                } else if !model.isGenerating {
                    // The empty state is the instruction. History opens here for
                    // meetings that were never summarized, so it has to say what
                    // to do rather than just report an absence.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No summary yet.").font(.callout)
                        Text("Check your notes, pick a template, then press Summarise below.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity)

            if !model.summary.isEmpty && !model.isGenerating {
                Button {
                    copySummary()
                } label: {
                    Label("Copy summary", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
            }

            if model.isGenerating && !model.summary.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.progressNote).font(.caption2).foregroundStyle(.secondary)
                }
            }

            if !model.speakerRows.isEmpty {
                Divider()
                SpeakerListView(
                    rows: model.speakerRows,
                    onRename: { model.rename($0, to: $1) },
                    onMerge: { model.merge($0, into: $1) })
            }
        }
    }
}
