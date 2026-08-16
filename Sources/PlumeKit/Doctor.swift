import AVFoundation
import FluidAudio
import Foundation

enum CheckStatus {
    case ok
    case warn(String)
    case fail(String)

    var isOK: Bool { if case .ok = self { return true } else { return false } }
}

struct Check {
    let name: String
    let status: CheckStatus
    let remediation: String?
}

enum DoctorReport {
    /// `probeAudio` runs the empirical capture tests. They take ~2s and play a
    /// short tone, so startup skips them; `doctor` and the settings window run
    /// them deliberately.
    static func run(recordingsRoot: URL, probeAudio: Bool = false) -> [Check] {
        // The level probe runs *before* the permission check, and the permission
        // check reads its result. Two reasons, in order of importance:
        //
        // 1. Invariant 5. Samples that came back non-zero are proof of the grant;
        //    `authorizationStatus` is a hint about it. Where they disagree, the
        //    capture wins.
        // 2. The probe is what triggers the prompt on a fresh install, so a
        //    status read before it is stale for the rest of the run. Observed
        //    2026-08-16 after the bundle id changed: "microphone — not yet
        //    requested, start a recording once" printed directly above a passing
        //    mic level probe, for a user who had just granted it.
        let micLevel = checkMicLevel(probe: probeAudio)
        return [
            checkMicrophone(levelProbe: micLevel.status),
            micLevel,
            checkSystemAudio(probe: probeAudio),
            checkRecordingsRoot(recordingsRoot),
            checkTranscription(),
        ]
    }

    /// Async because it talks to the daemon. Kept separate from `run` so the
    /// synchronous startup path stays synchronous.
    static func checkSummarization() async -> Check {
        let client = OllamaClient()
        let installed: [String]
        do {
            installed = try await client.tags()
        } catch OllamaClient.ClientError.unreachable {
            // Not an error at startup: Ollama.app starts its daemon lazily, so
            // a cold machine legitimately looks like this until something wakes it.
            return Check(
                name: "summarization",
                status: .warn("Ollama isn't running"),
                remediation: "start Ollama (or run `ollama list`); summaries need it, recording doesn't"
            )
        } catch {
            return Check(
                name: "summarization", status: .warn("Ollama check failed: \(error)"),
                remediation: nil)
        }

        let wanted = Config.summaryModel()
        guard installed.contains(wanted) else {
            return Check(
                name: "summarization",
                status: .fail("model \"\(wanted)\" is not installed"),
                remediation: installed.isEmpty
                    ? "run `ollama pull \(wanted)`"
                    : "run `ollama pull \(wanted)`, or pick one of: \(installed.prefix(4).joined(separator: ", "))"
            )
        }
        return Check(
            name: "summarization", status: .ok,
            remediation: "\(wanted) @ num_ctx \(Config.summaryContextTokens())")
    }

    /// `levelProbe` is the outcome of the empirical mic capture, when one ran.
    /// A probe that recorded real audio settles the question — the process
    /// cannot have captured samples it was not permitted to capture — and it is
    /// the only evidence available that does not go stale mid-run.
    static func checkMicrophone(levelProbe: CheckStatus = .warn("not probed")) -> Check {
        if levelProbe.isOK {
            return Check(name: "microphone", status: .ok, remediation: nil)
        }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not yet requested — will prompt on first recording"),
                remediation: "start a recording once; macOS will prompt"
            )
        case .denied, .restricted:
            return Check(
                name: "microphone",
                status: .fail("denied"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for Plume (or your terminal)"
            )
        @unknown default:
            return Check(name: "microphone", status: .fail("unknown state"), remediation: nil)
        }
    }

    /// There is no public API to query the system-audio-capture TCC state
    /// without side effects, so all we can do is describe the flow.
    /// Empirical, because nothing else works. An unauthorised tap reports
    /// success at every step and delivers well-formed all-zero buffers; return
    /// codes, stream formats and packet counts all look healthy. So play a tone
    /// and check the samples. See spikes/responsible-process/RESULTS.md.
    ///
    /// Only meaningful inside the .app bundle — from a terminal, TCC attributes
    /// the request to the shell and this correctly reports silence.
    static func checkSystemAudio(probe: Bool) -> Check {
        guard probe else {
            return Check(
                name: "system audio",
                status: .warn("not probed — pass `doctor` from the app to test capture for real"),
                remediation: nil
            )
        }
        guard let level = AudioProbe.probeSystemAudio() else {
            return Check(
                name: "system audio",
                status: .fail("could not create a process tap"),
                remediation: "System Settings → Privacy & Security → Screen & System Audio Recording → enable for Plume"
            )
        }
        if level.isSilent {
            return Check(
                name: "system audio",
                status: .fail("tap ran but captured pure silence (\(level.peakText))"),
                remediation: "System Settings → Privacy & Security → Screen & System Audio Recording → enable for Plume, then relaunch"
            )
        }
        // Report the level, not just "ok". This check exists because every
        // other signal lies; an unquantified pass would be one more of them.
        return Check(
            name: "system audio",
            status: .ok,
            remediation: "captured \(level.peakText), \(Int(level.nonZeroFraction * 100))% non-zero"
        )
    }

    /// A mic can be authorised, live, and still too quiet to transcribe well.
    /// Measured 2026-08-14: input volume 29/100 put speech at −31 dBFS. Audio is
    /// deleted after transcription, so a quiet meeting cannot be redone (R14b).
    static func checkMicLevel(probe: Bool) -> Check {
        guard probe else {
            return Check(name: "mic level", status: .warn("not probed"), remediation: nil)
        }
        guard let level = AudioProbe.probeMicrophone() else {
            return Check(
                name: "mic level",
                status: .warn("could not open the input device"),
                remediation: "System Settings → Sound → Input"
            )
        }
        // Thresholds are for ambient room tone during a ~1.5s probe, not speech.
        // Digital silence means a dead route; a very low peak means low input gain.
        if level.isSilent {
            return Check(
                name: "mic level",
                status: .fail("input is digitally silent"),
                remediation: "System Settings → Sound → Input — check the device and input volume"
            )
        }
        if level.peakDBFS < -55 {
            return Check(
                name: "mic level",
                status: .warn("very quiet (\(level.peakText) ambient) — speech may transcribe poorly"),
                remediation: "System Settings → Sound → Input — raise input volume to ~70%"
            )
        }
        return Check(
            name: "mic level", status: .ok,
            remediation: "ambient \(level.peakText)")
    }

    static func checkRecordingsRoot(_ root: URL) -> Check {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return Check(
                name: "recordings folder",
                status: .fail("can't create \(root.path)"),
                remediation: "check permissions on the parent directory"
            )
        }
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            return Check(
                name: "recordings folder",
                status: .fail("\(root.path) is not writable"),
                remediation: "check permissions on the directory"
            )
        }
        return Check(name: "recordings folder", status: .ok, remediation: nil)
    }

    /// Never discover a missing model after an important meeting: report
    /// whether the parakeet models are already in FluidAudio's cache.
    static func checkTranscription() -> Check {
        guard Config.transcriptionEnabled() else {
            return Check(
                name: "transcription",
                status: .warn("disabled in config"),
                remediation: nil
            )
        }
        let cache = AsrModels.defaultCacheDirectory(for: .v2)
        if AsrModels.modelsExist(at: cache, version: .v2) {
            return Check(name: "transcription", status: .ok, remediation: nil)
        }
        return Check(
            name: "transcription",
            status: .warn("parakeet models not downloaded (~600 MB)"),
            remediation: "downloads automatically on first transcription — record a short test session while online"
        )
    }

    static func print(_ checks: [Check]) {
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            Swift.print("\(mark) \(c.name): \(label)")
            if let r = c.remediation {
                Swift.print("    → \(r)")
            }
        }
    }

    /// True if no checks are in a hard-fail state. Warnings don't block.
    static func allOK(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .fail = $0.status { return false }
            return true
        }
    }
}
