import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let failureItem: NSMenuItem
    private let toggleItem: NSMenuItem

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onQuit: (() -> Void)?
    var onDismissFailure: (() -> Void)?
    var onRunDiagnostics: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        // Sticky failure line. A menubar app has no console; an error that only
        // appears in stderr is an error nobody sees. Click to dismiss.
        failureItem = NSMenuItem(
            title: "", action: #selector(dismissFailureClicked), keyEquivalent: "")
        failureItem.isHidden = true
        menu.addItem(failureItem)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(toggleItem)

        let openFolder = NSMenuItem(
            title: "Open meetings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        // Capture health can only be verified empirically, and only from inside
        // the bundle — see AudioProbe. This is the only place that check is
        // meaningful, so it needs to be reachable.
        let diagnostics = NSMenuItem(
            title: "Run diagnostics…",
            action: #selector(runDiagnosticsClicked),
            keyEquivalent: "d"
        )
        menu.addItem(diagnostics)

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsClicked),
            keyEquivalent: ","
        )
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Plume",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [toggleItem, openFolder, diagnostics, settings, quit, failureItem] {
            item.target = self
        }

        statusItem.menu = menu

        if let button = statusItem.button {
            let image = Self.featherImage()
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
        }
    }

    /// Render the whole menu from `AppState`. Called from an observation
    /// tracker, so every state change lands here — there is no path that
    /// updates one label without reconsidering the others.
    func render(_ state: AppState) {
        let isRecording = state.recording.isRecording
        stateLabel.title = isRecording
            ? "● recording · \(state.elapsedText ?? "0:00")"
            : (state.pendingCount > 0 ? "idle · \(state.pendingCount) pending" : "idle")
        toggleItem.title = isRecording ? "Stop recording" : "Start recording"
        statusItem.button?.contentTintColor = isRecording ? .systemRed : nil

        switch state.transcription {
        case .idle:
            transcriptionLabel.isHidden = true
        case .working(let name, let queued):
            transcriptionLabel.title = queued > 0
                ? "transcribing \(name) · \(queued) queued"
                : "transcribing \(name)"
            transcriptionLabel.isHidden = false
        case .failed(let name):
            transcriptionLabel.title = "transcription failed · \(name)"
            transcriptionLabel.isHidden = false
        }

        if let failure = state.lastFailure {
            failureItem.title = "⚠ \(failure.message) (\(failure.age)) — click to dismiss"
            failureItem.isHidden = false
        } else {
            failureItem.isHidden = true
        }
    }

    // Inlined Lucide feather SVG. Keeping it in source means the executable
    // has no separate resource bundle to install alongside it — true
    // single-binary.
    private static let featherSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" 
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" 
    stroke-linecap="round" stroke-linejoin="round">
    <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>
    <path d="M16 8 2 22"/>
    <path d="M17.5 15H9"/>
    </svg>
    """

    private static func featherImage() -> NSImage? {
        guard let data = featherSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
    @objc private func dismissFailureClicked() { onDismissFailure?() }
    @objc private func runDiagnosticsClicked() { onRunDiagnostics?() }
    @objc private func openSettingsClicked() { onOpenSettings?() }
}
