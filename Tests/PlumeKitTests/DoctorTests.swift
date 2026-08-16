import AVFoundation
import Foundation
import Testing

@testable import PlumeKit

@Suite("Doctor")
struct DoctorTests {

    /// Invariant 5, applied to the report itself: a probe that captured real
    /// samples proves the grant, whatever `AVCaptureDevice.authorizationStatus`
    /// says. This is not hypothetical — the status is read once per process, and
    /// the probe is what *triggers* the prompt, so on a fresh install the status
    /// is stale by the time it is printed.
    @Test("a passing level probe settles the microphone check")
    func probeBeatsCachedStatus() {
        #expect(DoctorReport.checkMicrophone(levelProbe: .ok).status.isOK)
    }

    /// Without a probe the check has nothing to go on and must fall back to the
    /// permission status — which at startup, where probes are skipped for the 2s
    /// they cost, is the only signal there is.
    @Test("no probe falls back to the permission status", arguments: [
        CheckStatus.warn("not probed"),
        CheckStatus.fail("no input device"),
    ])
    func fallsBackWithoutProbe(probe: CheckStatus) {
        // Whatever this machine's real TCC state is, the answer must be derived
        // from it rather than defaulting to ok.
        let check = DoctorReport.checkMicrophone(levelProbe: probe)
        #expect(check.name == "microphone")
        if case .ok = check.status {
            // Only legitimate if the permission really is granted here.
            #expect(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        }
    }

    @Test("a failed probe never reports the microphone as fine on its own")
    func failedProbeDoesNotPass() {
        let denied = DoctorReport.checkMicrophone(levelProbe: .fail("silence"))
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            #expect(!denied.status.isOK)
        }
    }
}
