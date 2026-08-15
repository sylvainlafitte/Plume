import AppKit
import SwiftUI

/// Browse past meetings.
///
/// Deliberately **not** an in-app markdown editor (docs/PLAN.md "Scope"): the
/// files are markdown in a folder and every Mac has a good editor, so this
/// window does the things an editor can't — regenerate a summary with a
/// different template, and rename or merge speakers, both of which have to
/// rewrite marked regions correctly.
///
/// The panel (Phase 5) handles everything about a *fresh* meeting; this is for
/// going back.
@MainActor
final class HistoryWindowController {
    private var window: NSWindow?
    private let model: HistoryModel

    init(root: URL) {
        model = HistoryModel(root: root)
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: HistoryView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Plume Meetings"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 760, height: 520))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        model.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
@Observable
final class HistoryModel: MeetingDetailModel {
    let root: URL
    private let engine = SummaryEngine()

    var entries: [MeetingEntry] = []
    var selection: URL?
    var summary: String = ""
    var speakerRows: [SpeakerRow] = []
    var templateID: String = Config.defaultTemplate()
    var isGenerating = false
    var error: String?
    // Opens on the result; selecting another meeting deliberately does *not*
    // reset this, so the tab never jumps as you move down the list.
    var detailTab: MeetingTab = .summary
    var notes: String = ""
    var progressNote = "Summarizing…"

    var templates: [SummaryTemplate] { TemplateStore.all() }
    // MeetingDetailModel conformance. A past meeting always has a transcript,
    // so summarizing is only blocked while one is already running.
    /// History is where you read one back, so it opens on the result.
    var initialTab: MeetingTab { .summary }
    var canSummarize: Bool { selected != nil }
    var blockedReason: String? { nil }
    var detailError: String? { error }
    func notesEdited() { scheduleSave() }
    var selected: MeetingEntry? { entries.first { $0.url == selection } }
    /// Surfaced as a count so a stalled queue is visible rather than inferred.
    var awaitingCount: Int { entries.filter(\.awaitingSummary).count }

    init(root: URL) {
        self.root = root
    }

    func reload() {
        entries = MeetingLibrary.entries(in: root)
        if selection == nil || !entries.contains(where: { $0.url == selection }) {
            selection = entries.first?.url
        }
        loadSelected()
    }

    func select(_ url: URL) {
        selection = url
        error = nil
        loadSelected()
    }

    private func loadSelected() {
        summary = ""
        speakerRows = []
        notes = ""
        guard let selected else { return }
        notes = NotesStore.read(from: selected.url)
        guard
            let document = try? String(
                contentsOf: selected.url.appendingPathComponent("meeting.md"),
                encoding: .utf8)
        else { return }

        if let existing = try? MeetingDocument.read(.summary, from: document) {
            summary = existing == "*pending*" ? "" : existing
        }
        if let transcript = try? MeetingDocument.read(.transcript, from: document) {
            let proposals = MeetingIdentity.load(from: selected.url)?.speakers ?? []
            speakerRows = SpeakerEditing.speakers(in: transcript)
                .filter { $0.label != Speaker.me.label }
                .map { entry in
                    SpeakerRow(
                        label: entry.label, samples: entry.samples,
                        proposal: proposals.first { $0.label == entry.label })
                }
        }
    }

    /// Debounced whole-file save, mirroring the panel — notes are free text and
    /// every keystroke would otherwise rewrite the file.
    private var saveTimer: Timer?

    func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushNotes() }
        }
    }

    func flushNotes() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard let selected else { return }
        try? NotesStore.write(notes, to: selected.url)
        // Keep meeting.md's Notes region in step, or a regenerated summary would
        // read the stale copy.
        try? MeetingDocument.updateRegion(
            .notes, at: selected.url.appendingPathComponent("meeting.md"), to: notes)
    }

    // MARK: - Actions

    func openInEditor() {
        guard let selected else { return }
        NSWorkspace.shared.open(selected.url.appendingPathComponent("meeting.md"))
    }

    /// The folder behind the list — the escape hatch that used to sit in the
    /// menu bar, now next to the list it belongs to.
    func openRootFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    func revealInFinder() {
        guard let selected else { return }
        NSWorkspace.shared.activateFileViewerSelecting(
            [selected.url.appendingPathComponent("meeting.md")])
    }

    func summarize() {
        guard let selected, !isGenerating else { return }
        // Debounced edits must reach disk before the engine reads them.
        flushNotes()
        detailTab = .summary
        isGenerating = true
        error = nil
        summary = ""
        progressNote = "Loading the model…"
        let template = TemplateStore.template(id: templateID) ?? TemplateStore.default()
        let url = selected.url

        Task { [engine] in
            do {
                try await engine.summarize(session: url, template: template) { progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.summary = progress.partial
                        self.progressNote = progress.windowsTotal > 1
                            ? "Summarizing — part \(progress.windowsDone + 1) of \(progress.windowsTotal)…"
                            : "Summarizing…"
                    }
                }
            } catch {
                await MainActor.run { self.error = "\(error)" }
            }
            await MainActor.run {
                self.isGenerating = false
                // Summarizing renames the folder once a title exists, so the
                // list — and the selection — have to be rebuilt.
                let stamp = url.lastPathComponent.prefix(15)
                self.entries = MeetingLibrary.entries(in: self.root)
                self.selection = self.entries
                    .first { $0.url.lastPathComponent.hasPrefix(stamp) }?.url ?? self.selection
                self.loadSelected()
            }
        }
    }

    func rename(_ label: String, to name: String) {
        edit { try SpeakerEditing.rename(label, to: name, in: $0) }
    }

    func merge(_ source: String, into destination: String) {
        edit { try SpeakerEditing.merge(source, into: destination, in: $0) }
    }

    private func edit(_ transform: @escaping (String) throws -> String) {
        guard let selected else { return }
        do {
            try SpeakerEditing.apply(
                to: selected.url.appendingPathComponent("meeting.md"), transform)
            error = nil
            loadSelected()
        } catch {
            self.error = "\(error)"
        }
    }
}

struct HistoryView: View {
    @Bindable var model: HistoryModel

    var body: some View {
        NavigationSplitView {
            list
        } detail: {
            if model.selected != nil {
                detail
            } else {
                ContentUnavailableView(
                    "No meetings yet",
                    systemImage: "waveform",
                    description: Text("Record one from the menu bar."))
            }
        }
        .onAppear { model.reload() }
    }

    private var list: some View {
        List(selection: Binding(
            get: { model.selection },
            set: { if let url = $0 { model.select(url) } })
        ) {
            ForEach(model.entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(entry.subtitle)
                            .font(.caption).foregroundStyle(.secondary)
                        if entry.awaitingSummary {
                            // Not an error — just work you haven't asked for yet.
                            Text("no summary")
                                .font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                        if case .failed = entry.blocker {
                            Text("failed").font(.caption2).foregroundStyle(.red)
                        }
                    }
                }
                .tag(entry.url)
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(model.entries.count) meetings")
                if model.awaitingCount > 0 {
                    Text("· \(model.awaitingCount) without a summary")
                }
                Spacer()
                Button {
                    model.openRootFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Open the meetings folder in Finder")
                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Rescan the meetings folder")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.bar)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let entry = model.selected {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title).font(.title3).bold().lineLimit(2)
                        Text(entry.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open in editor") { model.openInEditor() }
                    Button("Reveal") { model.revealInFinder() }
                }
            }

            // Same view the wrap-up panel uses, so the two cannot drift.
            MeetingDetailView(model: model)
        }
        .padding(16)
    }
}
