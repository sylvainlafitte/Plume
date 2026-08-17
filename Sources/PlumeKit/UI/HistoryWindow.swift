import AppKit
import SwiftUI

/// Browse past meetings.
///
/// Deliberately **not** an in-app markdown editor: the
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

    init() {
        model = HistoryModel()
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
    /// Read fresh, not stored: the folder can change in Settings while the app
    /// runs, and `show()` reloads, so the list follows it.
    var root: URL { Config.resolveRoot(cliOverride: nil) }
    private let engine = SummaryEngine()

    var entries: [MeetingEntry] = []
    var selection: URL?
    var summary: String = ""
    var speakerRows: [SpeakerRow] = []
    var templateID: String = Config.defaultTemplate()
    var isGenerating = false
    var detailError: String?
    // Opens on the result; selecting another meeting deliberately does *not*
    // reset this, so the tab never jumps as you move down the list.
    var detailTab: MeetingTab = .summary
    var notes: String = ""
    var progressNote = "Summarising…"

    var templates: [SummaryTemplate] { TemplateStore.all() }
    // MeetingDetailModel conformance. A past meeting always has a transcript,
    // so summarizing is only blocked while one is already running.
    /// History is where you read one back, so it opens on the result.
    var initialTab: MeetingTab { .summary }
    var canSummarize: Bool { selected != nil }
    var blockedReason: String? { nil }
    func notesEdited() { scheduleSave() }
    var selected: MeetingEntry? { entries.first { $0.url == selection } }
    /// MeetingDetailModel's view of "the meeting on screen" is the selection.
    var session: URL? { selection }

    func reload() {
        entries = MeetingLibrary.entries(in: root)
        if selection == nil || !entries.contains(where: { $0.url == selection }) {
            selection = entries.first?.url
        }
        loadSelected()
    }

    func select(_ url: URL) {
        selection = url
        detailError = nil
        loadSelected()
    }

    private func loadSelected() {
        summary = ""
        speakerRows = []
        notes = ""
        guard let selected else { return }
        notes = NotesStore.read(from: selected.url)
        reloadContent()
    }

    // Ignored by observation: a timer is not view state, and `lazy` and the
    // @Observable macro cannot coexist on a tracked property.
    @ObservationIgnored private lazy var autosave = NotesAutosave {
        [weak self] in self?.writeNotes()
    }

    func scheduleSave() { autosave.schedule() }
    func flushNotes() { autosave.flush() }

    private func writeNotes() {
        guard let selected else { return }
        try? NotesStore.write(notes, to: selected.url)
        // Keep meeting.md's Notes region in step, or a regenerated summary would
        // read the stale copy.
        //
        // Only once the file exists — a recorded-but-untranscribed meeting is
        // listed here and has no `meeting.md` yet, which is a normal resting
        // state, not an error. Beyond that the failure is surfaced rather than
        // dropped: `updateRegion` throws when a marker is missing (invariant 1),
        // and silently continuing would keep accepting notes that never reach
        // the document the summariser reads. Set, never cleared — the same
        // field carries summarize errors.
        let meetingURL = selected.url.appendingPathComponent("meeting.md")
        guard FileManager.default.fileExists(atPath: meetingURL.path) else { return }
        do {
            try MeetingDocument.updateRegion(.notes, at: meetingURL, to: notes)
        } catch {
            self.detailError = "\(error)"
        }
    }

    // MARK: - Actions

    /// Takes the meeting explicitly rather than acting on the selection, so a
    /// right-click on any row acts on *that* row.
    func openInEditor(_ url: URL) {
        NSWorkspace.shared.open(url.appendingPathComponent("meeting.md"))
    }

    /// The folder behind the list — the escape hatch that used to sit in the
    /// menu bar, now next to the list it belongs to.
    func openRootFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    /// Rename a meeting. Named for the meeting to keep it distinct from
    /// `rename(_:to:)`, which renames a *speaker*.
    func renameMeeting(_ url: URL, to title: String) {
        do {
            let renamed = try MeetingAdmin.rename(session: url, to: title)
            detailError = nil
            entries = MeetingLibrary.entries(in: root)
            // Follow the meeting to its new folder rather than losing the
            // selection to a URL that no longer exists.
            if selection == url { selection = renamed }
            loadSelected()
        } catch {
            self.detailError = "\(error)"
        }
    }

    /// Move a meeting to the Trash and select its neighbour.
    func deleteMeeting(_ url: URL) {
        // Where it sat, so the selection can land somewhere sensible instead of
        // jumping to the top of the list.
        let index = entries.firstIndex { $0.url == url }
        do {
            try MeetingAdmin.trash(session: url)
            detailError = nil
        } catch {
            self.detailError = "\(error)"
            return
        }
        entries = MeetingLibrary.entries(in: root)
        if selection == url {
            // Deleting the last meeting leaves nothing to select.
            selection = entries.isEmpty
                ? nil
                : entries[Swift.min(index ?? 0, entries.count - 1)].url
        }
        loadSelected()
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting(
            [url.appendingPathComponent("meeting.md")])
    }

    func summarize() { runSummarize(engine: engine) }

    /// - Parameter session: the URL the engine returned. Summarizing renames the
    ///   folder once a title exists, so the list — and the selection — are
    ///   rebuilt around the meeting's new home rather than around a prefix match
    ///   two same-minute meetings would both satisfy.
    func summarizingFinished(session: URL) {
        entries = MeetingLibrary.entries(in: root)
        selection = session
        loadSelected()
    }

    func rename(_ label: String, to name: String) {
        applySpeakerEdit { try SpeakerEditing.rename(label, to: name, in: $0) }
    }

    func merge(_ source: String, into destination: String) {
        applySpeakerEdit { try SpeakerEditing.merge(source, into: destination, in: $0) }
    }
}

struct HistoryView: View {
    @Bindable var model: HistoryModel
    /// Non-nil while the corresponding sheet is up. Held as entries rather than
    /// as booleans so the prompts can name the meeting they act on — "Delete
    /// this meeting?" is a worse question than naming it.
    @State private var renaming: MeetingEntry?
    @State private var deleting: MeetingEntry?
    @State private var draftTitle = ""

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
        .alert(
            "Rename meeting",
            isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } })
        ) {
            TextField("Title", text: $draftTitle)
            Button("Rename") {
                if let entry = renaming { model.renameMeeting(entry.url, to: draftTitle) }
                renaming = nil
            }
            .disabled(draftTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("The folder is renamed to match. Summarising again won't overwrite it.")
        }
        .confirmationDialog(
            deleting.map { "Move “\($0.title)” to the Trash?" } ?? "",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let entry = deleting { model.deleteMeeting(entry.url) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            // The audio is long gone by now, so this really is the only copy.
            Text("The recording was deleted after transcription, so the notes, "
                + "transcript and summary are the only copy.")
        }
    }

    /// Every per-meeting action, in one place.
    ///
    /// None of these is the reason the window exists — reading the summary and
    /// regenerating it are, and both are in the detail pane. Opening the file,
    /// revealing it, renaming and deleting are all escape hatches, so they sit
    /// behind one menu instead of lining the header with buttons that compete
    /// with the content. The same builder backs the row context menu, so a
    /// right-click and the header menu can never offer different things.
    @ViewBuilder
    private func rowActions(for entry: MeetingEntry) -> some View {
        Button("Open in editor") { model.openInEditor(entry.url) }
        Button("Reveal in Finder") { model.revealInFinder(entry.url) }
        Divider()
        Button("Rename…") {
            draftTitle = entry.title
            renaming = entry
        }
        Divider()
        Button("Delete…", role: .destructive) { deleting = entry }
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
                .contextMenu { rowActions(for: entry) }
            }
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("\(model.entries.count) meetings")
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
                    // `.button` is what makes a Menu adopt the same bordered
                    // chrome as a plain Button; the borderless style sits at a
                    // different baseline and reads as debris. The indicator
                    // arrow is hidden because the ellipsis already says "more".
                    // The label is *text*, not an SF Symbol: a bordered control
                    // sizes itself from its label, and an image label is short
                    // enough to come out half the height of the text buttons
                    // beside it. A text glyph inherits the same line metrics
                    // they do, so the heights match by construction rather than
                    // by a hardcoded frame that would drift with the font.
                    Menu {
                        rowActions(for: entry)
                    } label: {
                        Text("⋯")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }

            // Same view the wrap-up panel uses, so the two cannot drift.
            MeetingDetailView(model: model)
        }
        .padding(16)
    }
}
