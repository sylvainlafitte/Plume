import Foundation
import ServiceManagement

/// "Open at login", via `SMAppService.mainApp`.
///
/// The modern API and the reason this waited: it registers the **bundle**, so
/// it is meaningless for a bare binary — `swift run` has no bundle to register
/// and the call fails. Like capture, this is only testable from the `.app`
/// (AGENTS.md §3).
///
/// No `launchd` plist and no `LSSharedFileList`: `SMAppService` puts the item
/// under System Settings ▸ General ▸ Login Items where the user can revoke it,
/// which is the behaviour to want — a login item the app can add but the user
/// cannot see is the thing macOS spent years stamping out.
enum LoginItem {

    enum State: Equatable {
        case enabled
        case disabled
        /// The user disabled it in System Settings. We must not silently
        /// re-enable it: that is exactly the fight an app should never pick.
        case blockedByUser
        case unavailable(String)
    }

    /// **`.notFound` means "never registered", not "broken".**
    ///
    /// Measured 2026-08-16, because reading the docs suggested otherwise and the
    /// Settings toggle shipped disabled with "no app bundle" on a correctly
    /// bundled, signed app in /Applications. From inside the real bundle the
    /// status is `.notFound` before first use — `.notRegistered` is what the
    /// name suggests but not what this OS returns — and `register()` from that
    /// state succeeds and moves it straight to `.enabled`. So `.notFound` is
    /// mapped to `disabled`, i.e. an offer, and only a *failing* `register()`
    /// reports unavailable. Verified by registering and unregistering from
    /// Settings inside the installed bundle — `SMAppService` keys on the
    /// *calling* app, so a bare binary always reports `notFound` regardless.
    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered, .notFound: return .disabled
        case .requiresApproval: return .blockedByUser
        @unknown default: return .unavailable("unknown state")
        }
    }

    /// Returns the state after the attempt, so the caller reflects reality
    /// rather than what it asked for — a toggle that springs back is honest
    /// about `requiresApproval`, where the OS holds the final say.
    @discardableResult
    static func set(_ enabled: Bool) -> State {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
        return state
    }
}
