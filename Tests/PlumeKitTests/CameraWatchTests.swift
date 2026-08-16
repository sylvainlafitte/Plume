import Foundation
import Testing

@testable import PlumeKit

/// The detector's policy, tested without a camera. The CoreMediaIO read itself
/// is verified empirically instead (invariant 5) — a bare binary with no camera
/// grant enumerates the device and reads its running state.
///
/// `shouldNotify` is `mutating`, and `#expect` cannot call a mutating member on
/// its captured value, so each result is bound before it is asserted.
@Suite("Call detection policy")
struct CameraWatchTests {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test("notifies when the camera turns on while idle")
    func firesOnRisingEdge() {
        var policy = CameraWatch.Policy()
        let fired = policy.shouldNotify(cameraOn: true, isRecording: false, now: now)
        #expect(fired)
    }

    /// Edge-triggered, not level-triggered. A camera that has been on for an
    /// hour is not news, and repeating it would nag someone who deliberately
    /// chose not to record.
    @Test("does not repeat while the camera stays on")
    func doesNotRepeatWhileOn() {
        var policy = CameraWatch.Policy()
        let first = policy.shouldNotify(cameraOn: true, isRecording: false, now: now)
        let second = policy.shouldNotify(
            cameraOn: true, isRecording: false, now: now.addingTimeInterval(2))
        let third = policy.shouldNotify(
            cameraOn: true, isRecording: false, now: now.addingTimeInterval(4))
        #expect(first)
        #expect(!second)
        #expect(!third)
    }

    @Test("says nothing when Plume is already recording")
    func silentWhileRecording() {
        var policy = CameraWatch.Policy()
        let fired = policy.shouldNotify(cameraOn: true, isRecording: true, now: now)
        #expect(!fired)
    }

    /// A camera that flaps — leaving and rejoining a call, switching rooms —
    /// must not produce a stream of notifications.
    @Test("a second call within the cooldown is not announced")
    func respectsCooldown() {
        var policy = CameraWatch.Policy()
        let first = policy.shouldNotify(cameraOn: true, isRecording: false, now: now)
        _ = policy.shouldNotify(cameraOn: false, isRecording: false, now: now.addingTimeInterval(60))
        let second = policy.shouldNotify(
            cameraOn: true, isRecording: false, now: now.addingTimeInterval(120))
        #expect(first)
        #expect(!second)
    }

    @Test("a call after the cooldown is announced again")
    func firesAfterCooldown() {
        var policy = CameraWatch.Policy()
        let first = policy.shouldNotify(cameraOn: true, isRecording: false, now: now)
        _ = policy.shouldNotify(cameraOn: false, isRecording: false, now: now.addingTimeInterval(60))
        let later = now.addingTimeInterval(CameraWatch.Policy.cooldown + 1)
        let second = policy.shouldNotify(cameraOn: true, isRecording: false, now: later)
        #expect(first)
        #expect(second)
    }

    /// Recording through the first call must not consume the reminder for the
    /// next one: nothing was announced, so nothing should be suppressed.
    @Test("a suppressed-by-recording event does not start the cooldown")
    func recordingDoesNotArmCooldown() {
        var policy = CameraWatch.Policy()
        let suppressed = policy.shouldNotify(cameraOn: true, isRecording: true, now: now)
        _ = policy.shouldNotify(cameraOn: false, isRecording: true, now: now.addingTimeInterval(60))
        let later = policy.shouldNotify(
            cameraOn: true, isRecording: false, now: now.addingTimeInterval(120))
        #expect(!suppressed)
        #expect(later)
    }

    @Test("the real CoreMediaIO read answers without a camera permission")
    @MainActor
    func readingTheDeviceIsHarmless() {
        // Not asserting true/false — the camera's state during a test run is
        // whatever it is. The point is that the call returns rather than
        // trapping, prompting, or lighting the camera indicator.
        _ = CameraWatch.isCameraInUse()
    }
}
