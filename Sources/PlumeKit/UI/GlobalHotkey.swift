import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey, via Carbon's `RegisterEventHotKey`.
///
/// **Carbon, in 2026, on purpose.** The alternative is
/// `NSEvent.addGlobalMonitorForEvents`, which requires the Accessibility
/// permission — a permission that lets an app read every keystroke system-wide,
/// which is a wildly disproportionate thing to ask for "toggle recording", and
/// one a privacy-first meeting recorder should never request. `RegisterEventHotKey`
/// asks for nothing: the OS matches the combination and calls us, and we never
/// see any other key. It is deprecated-looking but not deprecated, and it is
/// still what every hotkey-using Mac app does.
///
/// One hotkey at a time is all Plume needs, so this owns a single registration
/// rather than a table.
@MainActor
final class GlobalHotkey {

    /// Default ⌥⌘R: ⌘R alone belongs to whatever app is frontmost, and adding
    /// ⌥ keeps it clear of the browser and editor bindings people actually use.
    static let defaultKeyCode = UInt32(kVK_ANSI_R)
    static let defaultModifiers = UInt32(cmdKey | optionKey)

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var onFire: (() -> Void)?

    /// Registers, replacing any previous registration. Returns false when the
    /// combination is already taken by another app — the OS refuses, and the
    /// honest thing is to say so rather than leave a dead shortcut in Settings.
    @discardableResult
    func register(
        keyCode: UInt32 = defaultKeyCode,
        modifiers: UInt32 = defaultModifiers,
        onFire: @escaping () -> Void
    ) -> Bool {
        unregister()
        self.onFire = onFire

        // The Carbon callback is a C function pointer: it cannot capture self,
        // so the instance travels through userData as an unretained pointer.
        // Unretained is safe because `unregister()` removes the handler before
        // this object can go away — see deinit.
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()

        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard id.signature == GlobalHotkey.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                // Carbon calls us on the main thread, but the compiler cannot
                // know that, and the callback runs outside actor isolation.
                MainActor.assumeIsolated { hotkey.onFire?() }
                return noErr
            },
            1, &spec, context, &handler)
        guard installed == noErr else { return false }

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let ref {
            UnregisterEventHotKey(ref)
            self.ref = nil
        }
        if let handler {
            RemoveEventHandler(handler)
            self.handler = nil
        }
        onFire = nil
    }

    /// Four-char code identifying our registration in the shared keyboard
    /// event stream, so a stray hot-key event from another registration in this
    /// process is ignored rather than toggling a recording.
    private static let signature: OSType = 0x504C_554D  // 'PLUM'

    /// `isolated deinit`, because the Carbon refs are main-actor state and a
    /// nonisolated deinit cannot touch them under Swift 6. Leaving the handler
    /// installed is not an option: the callback holds an unretained pointer to
    /// this object and would resurrect it after free.
    isolated deinit {
        unregister()
    }
}
