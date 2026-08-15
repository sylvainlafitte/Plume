import AppKit
import SwiftUI

/// Drives the floating panel through a meeting's life.
///
/// The flow the panel exists to support (docs/PLAN.md F8): stopping the
/// recording does not end the interaction. The panel stays up and expands, so
/// final thoughts can be added while transcription runs, and only then is the
/// summary generated. Summarization is **human-triggered**, which is why a
/// meeting can rest in `transcribed` indefinitely.
///
/// Views read this object directly instead of receiving values. An earlier
/// version rebuilt the whole SwiftUI tree on every state change, including the
/// once-a-second clock — which made the collapsed pill visibly flash. Now
/// `panel.show()` runs only when the *mode* changes, and observation updates
/// the individual labels.
@MainActor
@Observable
final class MeetingPanelController {

    private let panel = MeetingPanel()
    private let engine = SummaryEngine()

    private(set) var session: URL?
    private var startedAt: Date?

    // Observed by the views.
    var tab: WrapUpView.Tab = .notes
    var notes: String = ""
    var summary: String = ""
    var templateID: String = Config.defaultTemplate()
    var elapsed: String = "0:00"
    var isRecording = false
    var isGenerating = false
    var transcriptReady = false
    var error: String?
    var progressNote = "Summarizing…"
    var speakerRows: [SpeakerRow] = []

    var templates: [SummaryTemplate] { TemplateStore.all() }
    var title: String { session?.lastPathComponent ?? "Meeting" }
    var hasSession: Bool { session != nil }

    private var pollTimer: Timer?
    private var saveTimer: Timer?
    /// What the panel returns to when expanded from the pill.
    private var expandedMode: MeetingPanel.Mode = .recording

    /// Set by AppController so the panel's Stop button drives the same path as
    /// the menu bar's.
    var onStopRequested: (() -> Void)?

    // MARK: - Lifecycle

    func startedRecording(session: URL, at date: Date) {
        // A second meeting must never block on the first one's wrap-up; the
        // previous session simply drops back to the pending list.
        flushNotes()
        self.session = session
        startedAt = date
        notes = ""
        summary = ""
        error = nil
        isRecording = true
        transcriptReady = false
        speakerRows = []
        tab = .notes
        expandedMode = .recording
        show(.recording)
    }

    func tick() {
        guard let startedAt else { return }
        // Only a property changes; the view tree is not rebuilt.
        elapsed = NotesStore.clock(Date().timeIntervalSince(startedAt))
    }

    func stoppedRecording() {
        guard let session else { return }
        flushNotes()
        isRecording = false
        notes = NotesStore.read(from: session)
        transcriptReady = false
        tab = .notes
        expandedMode = .wrapUp
        show(.wrapUp)
        // meeting.md appears when transcription finishes; poll for it rather
        // than coupling the panel to the coordinator's internals.
        startPolling()
    }

    func requestStop() { onStopRequested?() }

    // MARK: - Panel state

    func collapse() { show(.pill) }
    func expand() { show(expandedMode) }

    /// Dismiss entirely. Reachable again from the menu bar — a panel you cannot
    /// close is worse than one you have to reopen.
    func close() {
        flushNotes()
        panel.hide()
    }

    func focus() {
        if !panel.isVisible || panel.mode == .pill { show(expandedMode) }
        panel.focus()
    }

    private func show(_ mode: MeetingPanel.Mode) {
        panel.show(mode, content: content(for: mode))
    }

    @ViewBuilder
    private func content(for mode: MeetingPanel.Mode) -> some View {
        switch mode {
        case .pill: MeetingPillView(controller: self)
        case .recording: RecordingStripView(controller: self)
        case .wrapUp: WrapUpView(controller: self)
        }
    }

    // MARK: - Notes

    /// Insert a timestamp at the end of the notes, on request only.
    func insertStamp() {
        guard let startedAt else { return }
        notes = NotesStore.appendingStamp(
            to: notes, elapsed: Date().timeIntervalSince(startedAt))
        scheduleSave()
    }

    /// Debounced whole-file save. Notes are free text, so every keystroke would
    /// otherwise rewrite the file; a short delay keeps that to a trickle while
    /// risking at most a second or two of typing on a crash.
    func scheduleSave() {
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
        syncNotesRegion()
    }

    /// Keep meeting.md's Notes region in step once it exists, so a summary
    /// never reads a stale copy.
    private func syncNotesRegion() {
        guard let session, transcriptReady else { return }
        try? MeetingDocument.updateRegion(
            .notes, at: session.appendingPathComponent("meeting.md"), to: notes)
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

        // Notes typed during wrap-up are newer than what transcription wrote.
        syncNotesRegion()

        if let transcript = try? MeetingDocument.read(.transcript, from: document) {
            let proposals = MeetingIdentity.load(from: session)?.speakers ?? []
            speakerRows = SpeakerEditing.speakers(in: transcript)
                .filter { $0.label != Speaker.me.label }
                .map { entry in
                    SpeakerRow(
                        label: entry.label,
                        samples: entry.samples,
                        proposal: proposals.first { $0.label == entry.label })
                }
        }
        if let existing = try? MeetingDocument.read(.summary, from: document),
            existing != "*pending*"
        {
            summary = existing
        }
    }

    // MARK: - Summarize

    func summarize() {
        guard let session, !isGenerating else { return }
        // Debounced edits must reach disk before the engine reads them.
        flushNotes()
        tab = .summary
        isGenerating = true
        error = nil
        summary = ""
        progressNote = "Loading the model…"

        let template = TemplateStore.template(id: templateID) ?? TemplateStore.default()
        Task { [engine] in
            do {
                try await engine.summarize(session: session, template: template) { progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.summary = progress.partial
                        self.progressNote = progress.windowsTotal > 1
                            ? "Summarizing — part \(progress.windowsDone + 1) of \(progress.windowsTotal)…"
                            : "Summarizing…"
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
                }
            }
        }
    }

    private func finishSummarize(session: URL) {
        isGenerating = false
        // Summarizing renames the folder once a title exists.
        if !FileManager.default.fileExists(atPath: session.path),
            let renamed = locateRenamed(from: session)
        {
            self.session = renamed
        }
        reloadSummary()
        checkForTranscript()
    }

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

    func rename(_ label: String, to name: String) {
        edit { try SpeakerEditing.rename(label, to: name, in: $0) }
    }

    func merge(_ source: String, into destination: String) {
        edit { try SpeakerEditing.merge(source, into: destination, in: $0) }
    }

    private func edit(_ transform: @escaping (String) throws -> String) {
        guard let session else { return }
        do {
            try SpeakerEditing.apply(
                to: session.appendingPathComponent("meeting.md"), transform)
            error = nil
            checkForTranscript()
        } catch {
            self.error = "\(error)"
        }
    }

    func openInEditor() {
        guard let session else { return }
        NSWorkspace.shared.open(session.appendingPathComponent("meeting.md"))
    }
}
