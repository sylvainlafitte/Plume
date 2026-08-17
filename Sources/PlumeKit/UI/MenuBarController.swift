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
    private let panelItem: NSMenuItem
    private let setupItem: NSMenuItem
    private let updateItem: NSMenuItem
    private var idleImage: NSImage?
    private var recordingImage: NSImage?

    var onToggle: (() -> Void)?
    var onOpenUpdate: (() -> Void)?
    var onQuit: (() -> Void)?
    var onDismissFailure: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenSetup: (() -> Void)?
    var onTogglePanel: (() -> Void)?
    var onOpenHistory: (() -> Void)?

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

        panelItem = NSMenuItem(
            title: "Show notes panel",
            action: #selector(togglePanelClicked),
            keyEquivalent: "n"
        )
        menu.addItem(panelItem)

        let history = NSMenuItem(
            title: "Meetings…",
            action: #selector(openHistoryClicked),
            keyEquivalent: "l"
        )
        menu.addItem(history)

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(openSettingsClicked),
            keyEquivalent: ","
        )
        menu.addItem(settings)

        // Setup is not a permanent fixture: it earns a menu slot only while
        // something it can fix is missing. `render` re-evaluates it, so it
        // disappears once the models land and comes back if they are deleted.
        setupItem = NSMenuItem(
            title: "Finish setup…",
            action: #selector(openSetupClicked),
            keyEquivalent: ""
        )
        menu.addItem(setupItem)

        // Same rule as setup: it earns a slot only while there is something to
        // act on, and it never says "up to date" — that is a line which would be
        // meaningless on all but a few days of the app's life.
        //
        // Here rather than in the status region at the top, because it is a thing
        // you *do* (it opens the release page), and because the top belongs to
        // this meeting: recording, transcribing, and what just failed.
        updateItem = NSMenuItem(
            title: "", action: #selector(openUpdateClicked), keyEquivalent: "")
        updateItem.isHidden = true
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit Plume",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        // "Open meetings folder" deliberately lives in the Meetings window's
        // sidebar footer instead: it points at the folder *behind that list*,
        // and the menu bar is for actions you need without opening anything.
        for item in [
            toggleItem, panelItem, history, settings, setupItem, updateItem, quit, failureItem,
        ] {
            item.target = self
        }

        statusItem.menu = menu

        // Idle stays a template so it follows the menu bar's own light/dark
        // foreground; recording is a fixed red that must not be re-tinted.
        idleImage = Self.featherImage()
        idleImage?.isTemplate = true
        recordingImage = Self.tinted(.systemRed)

        if let button = statusItem.button {
            button.image = idleImage
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
            : (state.callHint ? "idle · camera is on" : "idle")
        toggleItem.title = isRecording ? "Stop recording" : "Start recording"
        // Only while a meeting is actually in flight. Once it is summarized it
        // is history, and the Meetings window opens on exactly that — a second
        // route to the same place is clutter.
        panelItem.isEnabled = state.hasPanelSession
        panelItem.title = "Show notes panel"
        setupItem.isHidden = !SetupWindowController.isNeeded
        if let update = state.updateAvailable {
            updateItem.title = "Update to \(update.version)…"
            updateItem.isHidden = false
        } else {
            updateItem.isHidden = true
        }
        statusItem.button?.image = isRecording ? recordingImage : idleImage

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

    /// A pre-tinted copy, because `contentTintColor` does not colour a status
    /// item's **template** image: the template treatment wins, and the icon
    /// merely goes from the menu bar's foreground colour to black — which on a
    /// dark menu bar reads as the icon disappearing, not as "recording".
    /// Baking the colour in and turning the template flag off is the only way
    /// to get a colour that survives.
    private static func tinted(_ color: NSColor) -> NSImage? {
        guard let base = featherImage() else { return nil }
        let output = NSImage(size: base.size)
        let bounds = NSRect(origin: .zero, size: base.size)
        output.lockFocus()
        base.draw(in: bounds)
        color.set()
        bounds.fill(using: .sourceAtop)
        output.unlockFocus()
        // Template rendering would discard exactly what we just baked in.
        output.isTemplate = false
        return output
    }

    private static func featherImage() -> NSImage? {
        guard let data = featherSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func quitClicked() { onQuit?() }
    @objc private func dismissFailureClicked() { onDismissFailure?() }
    @objc private func openSettingsClicked() { onOpenSettings?() }

    @objc private func openSetupClicked() { onOpenSetup?() }
    @objc private func openUpdateClicked() { onOpenUpdate?() }
    @objc private func togglePanelClicked() { onTogglePanel?() }
    @objc private func openHistoryClicked() { onOpenHistory?() }
}
