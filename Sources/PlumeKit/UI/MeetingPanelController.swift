import AppKit
import SwiftUI

/// Drives the floating panel through a meeting's life.
///
/// The flow the panel exists to support: stopping the
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
    var meetingTitle: String?
    var finalizationFailed = false

    /// How many people are in *this* meeting, including you — the diarizer's cap
    /// (`Config.maxFarEndSpeakers`). Starts at the configured default on every
    /// recording and is never written back to config: who is in the room is a
    /// fact about one meeting, so a 5-person call must not re-tune every later
    /// 1:1. Read at diarization time, which starts at Stop — so this is editable
    /// exactly while the recording panel is up, and pointless afterwards.
    var participants: Int = Config.expectedParticipants()
    /// Set by AppController; carries the count onto the live session, which
    /// writes it into meta.json at Stop.
    var onParticipantsChanged: ((Int) -> Void)?
    var onTitleChanged: ((String) -> Void)?
    var onCommitStoredTitle: ((URL, String) throws -> String?)?
    var onBeginSummary: ((URL) -> Bool)?
    var onEndSummary: ((URL) -> Void)?
    var onIsSessionBusy: ((URL) -> Bool)?
    var onFinalizeSummary: ((URL) throws -> URL)?

    var templates: [SummaryTemplate] { TemplateStore.all() }
    // MeetingDetailModel conformance.
    /// The panel is where you write a meeting record.
    var initialTab: MeetingTab { .notes }
    var canSummarize: Bool { transcriptReady }
    var blockedReason: String? {
        if finalizationFailed { return "recording couldn't be finalized" }
        return transcriptReady ? nil : "transcribing…"
    }
    var canEditTitle: Bool {
        guard let session, !finalizationFailed else { return false }
        return !(onIsSessionBusy?(session) ?? false)
    }
    func notesEdited() { scheduleSave() }
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
        meetingTitle = nil
        finalizationFailed = false
        isRecording = true
        isFinished = false
        transcriptReady = false
        speakerRows = []
        detailTab = initialTab
        expandedMode = .recording
        // Back to the configured default: last meeting's count was last
        // meeting's, and re-reading Config picks up an edit to the file too.
        participants = Config.expectedParticipants()
        // Start ready for the title and notes people usually add at the beginning
        // of a call, but do not redirect typing from the app where the recording
        // was started. The first click still reaches the field.
        show(.recording, makeKey: false)
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

    func recordingFinalizationFailed(_ error: Error) {
        flushNotes()
        isRecording = false
        transcriptReady = false
        finalizationFailed = true
        detailError = "Couldn't finalize recording: \(error)"
        detailTab = initialTab
        expandedMode = .wrapUp
        pollTimer?.invalidate()
        pollTimer = nil
        show(.wrapUp)
    }

    func requestStop() { onStopRequested?() }

    func commitTitle(_ raw: String) {
        guard let title = MeetingTitleStore.normalize(raw), let session else { return }
        if isRecording {
            meetingTitle = title
            onTitleChanged?(title)
            return
        }
        do {
            let committed = try onCommitStoredTitle?(session, title)
                ?? MeetingTitleStore.setUserTitle(title, in: session)
            meetingTitle = committed ?? meetingTitle
            detailError = nil
        } catch {
            detailError = "\(error)"
        }
    }

    /// Applies a participant count to the live recording. Only ever called while
    /// recording — the value reaches the diarizer through meta.json, which is
    /// written at Stop.
    func setParticipants(_ count: Int) {
        participants = count
        onParticipantsChanged?(count)
    }

    // MARK: - Panel state

    func collapse() { show(.pill) }
    func expand() { show(expandedMode) }

    /// Hide during recording, where the panel remains the live controls. Closing
    /// a normal wrap-up retires it to Meetings; a failed finalization keeps its
    /// recovery handle reachable from the menu bar.
    func close() {
        flushNotes()
        panel.hide()
        guard !isRecording, !finalizationFailed else { return }
        retireSession()
    }

    func releaseSessionForDeletion(_ candidate: URL) {
        guard session == candidate else { return }
        flushNotes()
        panel.hide()
        retireSession()
    }

    private func retireSession() {
        pollTimer?.invalidate()
        pollTimer = nil
        session = nil
        isFinished = true
        onSessionFinished?()
    }

    func focus() {
        if !panel.isVisible || panel.mode == .pill { show(expandedMode) }
        panel.focus()
    }

    private func show(_ mode: MeetingPanel.Mode, makeKey: Bool = true) {
        panel.show(mode, content: content(for: mode), makeKey: makeKey)
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
    /// meeting's pending notes into the second's folder.
    func flushNotes() { autosave.flush() }

    func flushNotes(ifReferencing candidate: URL) {
        guard session == candidate else { return }
        flushNotes()
    }

    func adoptSession(from old: URL, to new: URL) {
        guard session == old else { return }
        session = new
        meetingTitle = MeetingTitleStore.title(in: new)
        reloadContent()
    }

    func revealSessionInFinder() {
        guard let session else { return }
        NSWorkspace.shared.activateFileViewerSelecting([session])
    }

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
        meetingTitle = MeetingTitleStore.title(in: session)

        // Notes typed during wrap-up are newer than what transcription wrote.
        syncNotesRegion()
        reloadContent()
    }

    // MARK: - Summarize

    func summarize() { runSummarize(engine: engine) }

    func beginSummary(session: URL) -> Bool {
        onBeginSummary?(session) ?? true
    }

    func endSummary(session: URL) {
        onEndSummary?(session)
    }

    func finalizeSummary(session: URL) throws -> URL {
        try onFinalizeSummary?(session) ?? MeetingSummaryFinalizer.finalize(session: session)
    }

    /// - Parameter session: the URL the engine returned, which already accounts
    ///   for the folder being renamed once a title exists. This used to be found
    ///   by scanning the parent for the `yyyy-MM-dd-HHmm` prefix — which two
    ///   meetings started in the same minute share, so the panel could adopt the
    ///   *other* meeting's folder.
    func summarizingFinished(session: URL) {
        self.session = session
        meetingTitle = MeetingTitleStore.title(in: session)
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
