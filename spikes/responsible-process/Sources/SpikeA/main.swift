import AppKit
import Foundation

// Spike A — does this process get its own TCC identity for system-audio capture?
//
// Run it two ways and compare:
//   1. `swift run SpikeA`        — shell-launched, the negative control
//   2. `./make-app.sh` then open SpikeA.app from Finder
//
// quill#54 reports (1) produces full-length digital silence with no error and no
// permission prompt, because TCC attributes the request to the responsible process —
// the terminal — which already has its own TCC record. If (2) also comes back silent,
// the .app packaging decision in docs/PLAN.md Phase 1 is invalid.

let captureDuration: TimeInterval = 3.0

let isBundled = Bundle.main.bundleIdentifier != nil
    && Bundle.main.bundlePath.hasSuffix(".app")
let launchContext = isBundled
    ? "BUNDLED  (\(Bundle.main.bundleIdentifier ?? "?"))"
    : "BARE BINARY (no bundle identity)"

var lines: [String] = []
// Top-level code in main.swift is @MainActor-isolated, so this helper must be too.
@MainActor func report(_ line: String) {
    lines.append(line)
    print(line)
    fflush(stdout)
}

report("── Plume Spike A · system-audio responsible-process probe ──")
report("launch context : \(launchContext)")
report("executable     : \(Bundle.main.bundlePath)")
report("date           : \(ISO8601DateFormatter().string(from: Date()))")
report("")
report("Playing a \(Int(captureDuration))s tone and capturing system audio…")

let tone = ToneGenerator()
var toneStarted = false
do {
    try tone.start()
    toneStarted = true
} catch {
    report("⚠️  tone generator failed to start: \(error)")
    report("    (capture will likely read silence for an unrelated reason — fix this first)")
}

// Let the output device settle before the tap starts measuring.
Thread.sleep(forTimeInterval: 0.5)

let probe = SystemAudioProbe()
var verdict: String
var passed = false

do {
    let result = try probe.run(duration: captureDuration)
    report("")
    report("tap created       : \(result.tapCreated ? "yes" : "no")")
    report("aggregate created : \(result.aggregateCreated ? "yes" : "no")")
    report("IOProc started    : \(result.ioProcStarted ? "yes" : "no")")
    report("stream format     : \(result.streamDescription)")
    report("IOProc callbacks  : \(result.callbacks)")
    report("samples seen      : \(result.totalSamples)")
    report("non-zero samples  : \(result.nonZeroSamples) (\(result.nonZeroPercent))")
    report("peak amplitude    : \(result.peakDBFS)")
    report("")

    passed = result.capturedRealAudio
    if passed {
        verdict = "✅ REAL AUDIO CAPTURED — this launch context has system-audio permission."
    } else if result.callbacks > 0 {
        verdict = """
            ❌ SILENT CAPTURE — the tap ran correctly and delivered \(result.callbacks) \
            well-formed all-zero buffers. This is an unauthorised tap, not a broken \
            audio graph. Exactly the quill#54 failure mode.
            """
    } else {
        verdict = "❌ NO CALLBACKS — the IOProc never fired. Different failure; investigate."
    }
} catch {
    verdict = "❌ PROBE ERROR — \(error)"
}

if toneStarted { tone.stop() }

report(verdict)
report("")

// Persist, because a Finder launch has nowhere to print to.
let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/plume-spike-a.log")
let entry = lines.joined(separator: "\n") + "\n" + String(repeating: "─", count: 60) + "\n"
if let handle = try? FileHandle(forWritingTo: logURL) {
    handle.seekToEndOfFile()
    handle.write(Data(entry.utf8))
    try? handle.close()
} else {
    try? entry.write(to: logURL, atomically: true, encoding: .utf8)
}
report("log: \(logURL.path)")

// A Finder-launched app needs to say something on screen.
if isBundled {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let alert = NSAlert()
    alert.messageText = passed ? "Spike A passed" : "Spike A failed"
    alert.informativeText = verdict + "\n\nFull log:\n\(logURL.path)"
    alert.alertStyle = passed ? .informational : .critical
    alert.addButton(withTitle: "OK")
    app.activate(ignoringOtherApps: true)
    alert.runModal()
}

exit(passed ? 0 : 1)
