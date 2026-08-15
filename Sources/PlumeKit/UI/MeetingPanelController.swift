import AppKit
import SwiftUI

/// Drives the floating panel through a meeting's life.
///
/// The flow the panel exists to support (docs/PLAN.md F8): stopping the
/// recording does not end the interaction. The panel stays up and expands, so
/// final thoughts can be added while transcription runs, and only then is the
/// summary generated. Summarization is therefore **human-triggered**, not
/// automatic — which is why a meeting can rest in `transcribed` indefinitely.
@MainActor
@Observable
final class MeetingPanelController {

    private let panel = MeetingPanel()
    private let engine = SummaryEngine()

    /// The session the panel is currently about. Changes when a recording
    /// starts, or when a new one starts while the last is still in wrap-up.
    private(set) var session: URL?
    private var startedAt: Date?

    // Wrap-up state
    var tab: WrapUpView.Tab = .notes
    var notes: String = ""
    var summary: String = ""
    var templateID: String = Config.defaultTemplate()
    var isGenerating = false
    var error: String?
    private var speakerRows: [SpeakerRow] = []
    private var transcriptReady = false
    private var pollTimer: Timer?
    private var saveTimer: Timer?
    /// What the panel returns to when expanded from the pill.
    private var expandedMode: MeetingPanel.Mode = .recording

    var isVisible: Bool { panel.isVisible }

    // MARK: - Recording

    func startedRecording(session: URL, at date: Date) {
        // A second meeting starting must never block on the first one's
        // wrap-up; the previous session simply drops back to the pending list.
        flushNotes()
        self.session = session
        startedAt = date
        notes = ""
        summary = ""
        error = nil
        transcriptReady = false
        speakerRows = []
        tab = .notes
        expandedMode = .recording
        render(.recording)
    }

    func tick() {
        guard panel.isVisible, panel.mode == .recording || panel.mode == .pill else { return }
        render(panel.mode)
    }

    /// Collapse to the pill, or expand back to whatever state we were in.
    func collapse() { render(.pill) }
    func expand() { render(expandedMode) }

    /// True once a meeting exists to show — the menubar item is meaningless
    /// before that.
    var hasSession: Bool { session != nil }

    func stoppedRecording() {
        guard let session else { return }
        flushNotes()
        notes = (try? NotesStore.markWrapUp(in: session)) ?? NotesStore.read(from: session)
        transcriptReady = false
        tab = .notes
        expandedMode = .wrapUp
        render(.wrapUp)
        // meeting.md appears when transcription finishes; poll for it rather
        // than coupling the panel to the coordinator's internals.
        startPolling()
    }

    func focus() {
        if panel.mode == .pill { expand() } else { render(panel.mode) }
        panel.focus()
    }

    // MARK: - Notes

    /// Insert a timestamp at the end of the notes, on request only.
    private func insertStamp() {
        guard let startedAt else { return }
        notes = NotesStore.appendingStamp(
            to: notes, elapsed: Date().timeIntervalSince(startedAt))
        scheduleSave()
        render(panel.mode)
    }

    /// Debounced whole-file save. Notes are free text now, so every keystroke
    /// would otherwise rewrite the file; a short delay keeps that to a trickle
    /// while risking at most a second or two of typing on a crash.
    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushNotes() }
        }
    }

    private func flushNotes() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard let session else { return }
        try? NotesStore.write(notes, to: session)
        // If the transcript is already written, keep meeting.md's Notes region
        // in step — otherwise a summary would read a stale copy.
        syncNotesRegion()
    }

    private func syncNotesRegion() {
        guard let session, transcriptReady else { return }
        let url = session.appendingPathComponent("meeting.md")
        try? MeetingDocument.updateRegion(.notes, at: url, to: notes)
    }

    // MARK: - Transcript arrival

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForTranscript() }
        }
        checkForTranscript()
    }

    private func checkForTranscript() {
        guard let session else { return }
        let url = session.appendingPathComponent("meeting.md")
        guard FileManager.default.fileExists(atPath: url.path),
            let document = try? String(contentsOf: url, encoding: .utf8)
        else { return }

        pollTimer?.invalidate()
        pollTimer = nil
        transcriptReady = true

        // The notes typed during wrap-up are newer than what transcription
        // wrote, so push them in rather than letting the file overwrite them.
        syncNotesRegion()

        if let transcript = try? MeetingDocument.read(.transcript, from: document) {
            let proposals = MeetingIdentity.load(from: session)?.speakers ?? []
            speakerRows = SpeakerEditing.speakers(in: transcript).map { entry in
                SpeakerRow(
                    label: entry.label,
                    samples: entry.samples,
                    proposal: proposals.first { $0.label == entry.label })
            }
            // "me" is you; there is nothing to name or merge.
            speakerRows.removeAll { $0.label == Speaker.me.label }
        }
        if let existing = try? MeetingDocument.read(.summary, from: document),
            existing != "*pending*"
        {
            summary = existing
        }
        render(.wrapUp)
    }

    // MARK: - Summarize

    private func summarize() {
        guard let session, !isGenerating else { return }
        // Debounced edits must reach disk before the engine reads them.
        flushNotes()
        tab = .summary
        isGenerating = true
        error = nil
        summary = ""
        render(.wrapUp)

        let template = TemplateStore.template(id: templateID) ?? TemplateStore.default()
        Task { [engine] in
            do {
                try await engine.summarize(session: session, template: template) { progress in
                    Task { @MainActor [weak self] in
                        self?.summary = progress.partial
                        self?.render(.wrapUp)
                    }
                }
                await MainActor.run { self.finishSummarize(session: session) }
            } catch {
                await MainActor.run {
                    self.isGenerating = false
                    self.error = "\(error)"
                    // The previous summary is untouched on disk (invariant 2);
                    // reload so the panel shows what is actually there.
                    self.reloadSummary()
                    self.render(.wrapUp)
                }
            }
        }
    }

    private func finishSummarize(session: URL) {
        isGenerating = false
        // Summarizing can rename the folder, so re-resolve before reading.
        if !FileManager.default.fileExists(atPath: session.path),
            let renamed = locateRenamed(from: session)
        {
            self.session = renamed
        }
        reloadSummary()
        checkForTranscript()
        tab = .summary
        render(.wrapUp)
    }

    /// The folder gains a title slug during summarization; find it again.
    private func locateRenamed(from old: URL) -> URL? {
        let parent = old.deletingLastPathComponent()
        let stamp = old.lastPathComponent.prefix(15)
        return (try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.hasPrefix(stamp) }
    }

    private func reloadSummary() {
        guard let session,
            let document = try? String(
                contentsOf: session.appendingPathComponent("meeting.md"), encoding: .utf8),
            let existing = try? MeetingDocument.read(.summary, from: document)
        else { return }
        summary = existing == "*pending*" ? "" : existing
    }

    // MARK: - Speakers

    private func rename(_ label: String, to name: String) {
        edit { try SpeakerEditing.rename(label, to: name, in: $0) }
    }

    private func merge(_ source: String, into destination: String) {
        edit { try SpeakerEditing.merge(source, into: destination, in: $0) }
    }

    private func edit(_ transform: @escaping (String) throws -> String) {
        guard let session else { return }
        let url = session.appendingPathComponent("meeting.md")
        do {
            try SpeakerEditing.apply(to: url, transform)
            error = nil
            checkForTranscript()
        } catch {
            self.error = "\(error)"
            render(.wrapUp)
        }
    }

    // MARK: - Rendering

    private var elapsedText: String {
        startedAt.map { NotesStore.clock(Date().timeIntervalSince($0)) } ?? "0:00"
    }

    private func render(_ mode: MeetingPanel.Mode) {
        switch mode {
        case .pill:
            panel.show(
                .pill,
                content: MeetingPillView(
                    isRecording: expandedMode == .recording,
                    elapsed: elapsedText,
                    onExpand: { [weak self] in self?.expand() }))
        case .recording:
            panel.show(
                .recording,
                content: RecordingStripView(
                    elapsed: elapsedText,
                    notes: Binding(
                        get: { self.notes },
                        set: { self.notes = $0; self.scheduleSave() }),
                    onStamp: { [weak self] in self?.insertStamp() },
                    onStop: { [weak self] in self?.onStopRequested?() },
                    onCollapse: { [weak self] in self?.collapse() }))
        case .wrapUp:
            panel.show(
                .wrapUp,
                content: WrapUpView(
                    tab: Binding(get: { self.tab }, set: { self.tab = $0; self.render(.wrapUp) }),
                    notes: Binding(
                        get: { self.notes },
                        set: { self.notes = $0; self.scheduleSave() }),
                    title: session?.lastPathComponent ?? "Meeting",
                    transcriptReady: transcriptReady,
                    summary: summary,
                    isGenerating: isGenerating,
                    templates: TemplateStore.all(),
                    templateID: Binding(
                        get: { self.templateID },
                        set: { self.templateID = $0; self.render(.wrapUp) }),
                    speakers: speakerRows,
                    error: error,
                    onSummarize: { [weak self] in self?.summarize() },
                    onOpenInEditor: { [weak self] in self?.openInEditor() },
                    onCollapse: { [weak self] in self?.collapse() },
                    onRename: { [weak self] in self?.rename($0, to: $1) },
                    onMerge: { [weak self] in self?.merge($0, into: $1) }))
        }
    }

    private func openInEditor() {
        guard let session else { return }
        NSWorkspace.shared.open(session.appendingPathComponent("meeting.md"))
    }

    /// Set by AppController so the panel's Stop button drives the same path as
    /// the menu bar's.
    var onStopRequested: (() -> Void)?
}
