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
final class MeetingPanelController: MeetingDetailModel {

    private let panel = MeetingPanel()
    private let engine = SummaryEngine()

    var session: URL?
    private var startedAt: Date?

    // Observed by the views.
    var detailTab: MeetingTab = .notes
    var notes: String = ""
    var summary: String = ""
    var templateID: String = Config.defaultTemplate()
    var elapsed: String = "0:00"
    var isRecording = false
    var isGenerating = false
    var transcriptReady = false
    var detailError: String?
    var progressNote = "Summarising…"
    var speakerRows: [SpeakerRow] = []

    var templates: [SummaryTemplate] { TemplateStore.all() }
    // MeetingDetailModel conformance.
    /// The panel is where you write a meeting record.
    var initialTab: MeetingTab { .notes }
    var canSummarize: Bool { transcriptReady }
    var blockedReason: String? { transcriptReady ? nil : "transcribing…" }
    func notesEdited() { scheduleSave() }
    var title: String { session?.lastPathComponent ?? "Meeting" }
    /// True while a meeting is still in flight — recording, or stopped but not
    /// yet summarized. Once summarized it belongs to the Meetings window.
    var hasSession: Bool { session != nil && !isFinished }
    private var isFinished = false

    private var pollTimer: Timer?
    // Ignored by observation: a timer is not view state, and `lazy` and the
    // @Observable macro cannot coexist on a tracked property.
    @ObservationIgnored private lazy var autosave = NotesAutosave {
        [weak self] in self?.writeNotes()
    }
    /// What the panel returns to when expanded from the pill.
    private var expandedMode: MeetingPanel.Mode = .recording

    /// Set by AppController so the panel's Stop button drives the same path as
    /// the menu bar's.
    var onStopRequested: (() -> Void)?
    /// Lets AppController refresh menubar state when a meeting becomes history.
    var onSessionFinished: (() -> Void)?

    // MARK: - Lifecycle

    func startedRecording(session: URL, at date: Date) {
        // A second meeting must never block on the first one's wrap-up; the
        // previous session simply drops back to the pending list.
        flushNotes()
        self.session = session
        startedAt = date
        notes = ""
        summary = ""
        detailError = nil
        isRecording = true
        isFinished = false
        transcriptReady = false
        speakerRows = []
        detailTab = initialTab
        expandedMode = .recording
        // Starts collapsed. Most of a call is spent not writing anything, and
        // the notes field is one click away — whereas a strip that appears
        // unbidden over a call has to be dismissed before it earns its place.
        // Expanding is what `focus()` does, so the menu bar and the pill both
        // reach the same state.
        show(.pill)
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
        detailTab = initialTab
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

    func scheduleSave() { autosave.schedule() }

    /// Runs before `session` is reassigned in `startedRecording` — a second
    /// meeting starting while the first is in wrap-up must not write the first
    /// meeting's pending notes into the second's folder (PLAN R11).
    func flushNotes() { autosave.flush() }

    private func writeNotes() {
        guard let session else { return }
        try? NotesStore.write(notes, to: session)
        syncNotesRegion()
    }

    /// Keep meeting.md's Notes region in step once it exists, so a summary
    /// never reads a stale copy.
    ///
    /// The failure is surfaced rather than dropped: `updateRegion` throws only
    /// when a marker is missing, which means the user's own edit has made the
    /// file unwritable by us (invariant 1). Silently continuing would keep
    /// accepting notes that never reach the document the summariser reads.
    private func syncNotesRegion() {
        guard let session, transcriptReady else { return }
        do {
            try MeetingDocument.updateRegion(
                .notes, at: session.appendingPathComponent("meeting.md"), to: notes)
        } catch {
            // Set, never cleared here: the same field carries summarize errors,
            // and a later keystroke succeeding says nothing about those.
            self.detailError = "\(error)"
        }
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
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        pollTimer?.invalidate()
        pollTimer = nil
        transcriptReady = true

        // Notes typed during wrap-up are newer than what transcription wrote.
        syncNotesRegion()
        reloadContent()
    }

    // MARK: - Summarize

    func summarize() { runSummarize(engine: engine) }

    /// - Parameter session: the URL the engine returned, which already accounts
    ///   for the folder being renamed once a title exists. This used to be found
    ///   by scanning the parent for the `yyyy-MM-dd-HHmm` prefix — which two
    ///   meetings started in the same minute share, so the panel could adopt the
    ///   *other* meeting's folder.
    func summarizingFinished(session: URL) {
        self.session = session
        isFinished = true
        onSessionFinished?()
        reloadContent()
        checkForTranscript()
    }

    // MARK: - Speakers

    func rename(_ label: String, to name: String) {
        applySpeakerEdit { try SpeakerEditing.rename(label, to: name, in: $0) }
    }

    func merge(_ source: String, into destination: String) {
        applySpeakerEdit { try SpeakerEditing.merge(source, into: destination, in: $0) }
    }
}
