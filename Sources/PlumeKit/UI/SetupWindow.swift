import AVFoundation
import AppKit
import SwiftUI

/// Setup **and** health, in one window, rendering `DoctorReport`.
///
/// These were two surfaces answering the same six questions: a setup window with
/// buttons, and a "Run checks…" modal alert with the same findings as text.
/// Merged 2026-08-16, because the split had already produced two verdicts from
/// one probe — `DoctorReport.checkMicLevel` and this window's own reading of
/// `AudioProbe.Level` — which is the drift AGENTS.md §4 records for the panel and
/// the history window, caught a day in rather than a phase later.
///
/// `DoctorReport` stays the single engine; this is a renderer, and so is
/// `plume doctor` on a terminal. What the window adds is *agency*: a check that
/// fails gets the button that fixes it, instead of a sentence describing what to
/// type. It is also why the alert is gone — an alert cannot download a model or
/// ask for a permission.
///
/// It is a **window, not a wizard**: nothing here is a step you complete in
/// order, and none of it blocks recording — a meeting with no models still
/// records and waits at `recorded` until they arrive.
///
/// It opens by itself only when the models are missing, the one state where
/// Plume genuinely cannot do its job. Not for Ollama being cold, which is a
/// normal first-run condition that resolves itself.
@MainActor
final class SetupWindowController {
    private var window: NSWindow?

    static var isNeeded: Bool { !ModelSetup.allReady }

    func show(root: URL) {
        if window == nil {
            let hosting = NSHostingController(rootView: SetupView(root: root))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Plume Setup & Checks"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SetupView: View {
    let root: URL

    @State private var checks: [Check] = []
    @State private var busy: String?
    @State private var download: DownloadState?
    @State private var probed = false

    private struct DownloadState {
        var progress: ModelSetup.Progress?
        var error: String?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Plume records, transcribes and summarizes meetings on this Mac.")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing is sent anywhere, so everything it needs has to live here too.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                ForEach(checks, id: \.name) { check in
                    row(for: check)
                }
            }

            if let download {
                downloadProgress(download)
            }

            Divider()

            HStack(spacing: 8) {
                Button(probed ? "Check capture again" : "Check capture…") {
                    Task { await refresh(probeAudio: true) }
                }
                .disabled(busy != nil)
                if let busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("Capture checks play a short tone and record for a second — the only way to "
                + "know audio works, because a tap without permission reports success and "
                + "records silence. You can close this and record straight away: a meeting "
                + "made before the models arrive simply waits for them.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 480, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            // No probes on open: they cost ~2s and play a tone, which a window
            // must never do merely for appearing.
            await refresh(probeAudio: false)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func row(for check: Check) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Label(title(for: check), systemImage: icon(for: check.status))
                    .foregroundStyle(colour(for: check.status))
                Spacer()
                action(for: check)
            }
            if let detail = detail(for: check) {
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The check names are terse because they were written for a terminal.
    private func title(for check: Check) -> String {
        switch check.name {
        case "microphone": return "Microphone permission"
        case "mic level": return "Microphone capture"
        case "system audio": return "System audio capture"
        case "recordings folder": return "Meetings folder"
        case "transcription": return "On-device models"
        case "summarization": return "Summaries (Ollama)"
        default: return check.name
        }
    }

    /// A passing check shows its measurement: `doctor` reports the captured
    /// level rather than a bare "ok" precisely because every other signal here
    /// can lie, and that reasoning survives the move to a window.
    private func detail(for check: Check) -> String? {
        switch check.status {
        case .ok:
            return check.remediation
        case .warn(let message), .fail(let message):
            return [message, check.remediation].compactMap { $0 }.joined(separator: " — ")
        }
    }

    private func icon(for status: CheckStatus) -> String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "circle.dashed"
        case .fail: return "exclamationmark.triangle.fill"
        }
    }

    private func colour(for status: CheckStatus) -> Color {
        switch status {
        case .ok: return .green
        case .warn: return .secondary
        case .fail: return .orange
        }
    }

    /// The whole point of merging: the fix sits next to the finding.
    @ViewBuilder
    private func action(for check: Check) -> some View {
        switch check.name {
        case "transcription":
            if !check.status.isOK {
                Button("Download (~\(ModelSetup.approximateDownloadMB) MB)") {
                    Task { await runDownload() }
                }
                .disabled(download?.progress != nil)
            }
        case "microphone", "mic level", "system audio":
            if !check.status.isOK {
                Button(grantTitle) { Task { await grantAndVerify() } }
                    .disabled(busy != nil)
            }
        case "recordings folder":
            Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
        default:
            EmptyView()
        }
    }

    /// Once macOS has granted the microphone there is nothing left to ask for —
    /// system audio has no queryable status at all, so all that remains is the
    /// capture that proves it.
    private var grantTitle: String {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "Verify…" : "Grant…"
    }

    @ViewBuilder
    private func downloadProgress(_ state: DownloadState) -> some View {
        if let progress = state.progress {
            switch progress.phase {
            case .listing:
                ProgressView("\(progress.component) — contacting the model repository")
                    .font(.caption)
            case .downloading(let fraction):
                ProgressView(value: fraction) {
                    Text("\(progress.component) — \(Int(fraction * 100))%").font(.caption)
                }
            case .compiling(let model):
                // Compilation reports no fraction and is slow the first time. An
                // indeterminate bar with a name beats a bar frozen at 100%.
                ProgressView("\(progress.component) — preparing \(model)")
                    .font(.caption)
            }
        } else if let error = state.error {
            Text(error).font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func refresh(probeAudio: Bool) async {
        if probeAudio { busy = "Playing a tone and recording…" }
        defer { busy = nil }

        let root = self.root
        var result = await Task.detached(priority: .userInitiated) {
            DoctorReport.run(recordingsRoot: root, probeAudio: probeAudio)
        }.value
        result.append(await DoctorReport.checkSummarization())
        checks = result
        if probeAudio { probed = true }
    }

    /// Ask, then prove. The request must return before the probes run, or the
    /// tone plays into an open permission sheet.
    private func grantAndVerify() async {
        busy = "Waiting for macOS…"
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        await refresh(probeAudio: true)
    }

    private func runDownload() async {
        download = DownloadState(progress: ModelSetup.Progress(
            component: "Transcription", phase: .listing))
        do {
            try await ModelSetup.downloadIfNeeded { progress in
                Task { @MainActor in download?.progress = progress }
            }
            download = nil
        } catch {
            // Recoverable: the button returns rather than the window becoming a
            // dead end.
            download = DownloadState(
                progress: nil, error: "Download failed: \(error.localizedDescription)")
        }
        await refresh(probeAudio: false)
    }
}
