import CoreMediaIO
import Foundation

/// Notices when the camera turns on, as a hint that a meeting is starting.
///
/// **Why the camera and not the microphone.** The mic tells you someone is
/// *already talking*; the camera turns on when you join, before anyone has said
/// anything — which is when a reminder is still useful rather than a reproach.
/// It also costs nothing in permissions: `kCMIODevicePropertyDeviceIsRunningSomewhere`
/// is readable without the camera TCC grant (measured — a bare binary with no
/// grant enumerates the device and reads the property), and Plume never opens a
/// stream, so no camera indicator lights up because of us.
///
/// **What it cannot see.** Audio-only calls — a phone-style Zoom, a Slack huddle
/// with video off, a conference room where you are the camera-less one. Those
/// are misses, and misses are the right failure: this feature must never be the
/// reason a recording starts, only a reminder that one hasn't.
///
/// Polling, not a CMIO property listener: the reads are trivial, the device list
/// changes when anything is plugged in (which a listener must then re-subscribe
/// to), and a 2s delay on a notification about a meeting that is starting is
/// imperceptible. The listener version is more elegant and more moving parts.
@MainActor
final class CameraWatch {

    /// Edge-triggered, with a hold-down. Pure, so the policy is testable
    /// without a camera.
    struct Policy: Equatable {
        /// Camera was on at the previous poll.
        private(set) var wasOn = false
        /// When we last told the user, so a camera that flaps between calls
        /// doesn't produce a stream of notifications.
        private(set) var lastNotified: Date?

        /// Don't mention it again within this window. A meeting that ends and
        /// restarts inside ten minutes is the same meeting as far as anyone
        /// reaching for a notification is concerned.
        static let cooldown: TimeInterval = 600

        /// Returns true when the user should be told, and folds the new state in.
        mutating func shouldNotify(cameraOn: Bool, isRecording: Bool, now: Date) -> Bool {
            defer { wasOn = cameraOn }
            // Only the moment it turns on. A camera that has been on for an
            // hour is not news, and re-notifying would punish anyone who
            // deliberately chose not to record.
            guard cameraOn, !wasOn else { return false }
            // Nothing to remind about if Plume is already doing it.
            guard !isRecording else { return false }
            if let lastNotified, now.timeIntervalSince(lastNotified) < Self.cooldown {
                return false
            }
            lastNotified = now
            return true
        }
    }

    private var policy = Policy()
    private var timer: Timer?
    private let onDetected: () -> Void
    private let isRecording: () -> Bool

    static let pollInterval: TimeInterval = 2

    init(isRecording: @escaping () -> Bool, onDetected: @escaping () -> Void) {
        self.isRecording = isRecording
        self.onDetected = onDetected
    }

    /// Starts only if the user asked for it. Off by default (`call_detection`).
    func startIfEnabled() {
        stop()
        guard Config.callDetectionEnabled() else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard policy.shouldNotify(
            cameraOn: Self.isCameraInUse(), isRecording: isRecording(), now: Date())
        else { return }
        onDetected()
    }

    // MARK: - CoreMediaIO

    /// True if any video device is streaming to *some* process. It cannot say
    /// which one — CMIO reports the device's state, not its clients — so the
    /// notification never names an app.
    static func isCameraInUse() -> Bool {
        devices().contains { isRunning($0) == true }
    }

    private static func devices() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == 0
        else { return [] }

        var ids = [CMIOObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard !ids.isEmpty,
            CMIOObjectGetPropertyData(
                CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &ids) == 0
        else { return [] }
        return ids
    }

    /// nil when the device doesn't answer — treated as "not in use" by the
    /// caller, because a detector that guesses "on" would nag.
    private static func isRunning(_ device: CMIOObjectID) -> Bool? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == 0
        else { return nil }
        return value != 0
    }
}
