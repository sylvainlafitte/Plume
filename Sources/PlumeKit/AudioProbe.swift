import AVFoundation
import CoreAudio
import Foundation

/// Empirical audio checks. The only way to know capture actually works.
///
/// Every other signal lies. A system tap created without permission returns
/// `noErr`, reports a correct stream format, creates its aggregate device, and
/// fires its IOProc at exactly the right rate — while every sample is zero.
/// Measured in spikes/responsible-process/RESULTS.md. So `doctor` plays a tone
/// and asserts the samples aren't all zero; nothing cheaper is trustworthy.
enum AudioProbe {

    struct Level {
        let peak: Float
        let nonZeroFraction: Double

        var peakDBFS: Double { peak > 0 ? 20 * log10(Double(peak)) : -.infinity }
        var peakText: String {
            peak > 0 ? String(format: "%.1f dBFS", peakDBFS) : "-inf dBFS"
        }
        var isSilent: Bool { peak <= 0.0001 }
    }

    // MARK: - System audio

    /// Play a short tone, capture the system tap, and report the level seen.
    /// Returns nil if the tap could not be built at all (a different failure).
    static func probeSystemAudio(duration: TimeInterval = 1.5) -> Level? {
        let tone = ToneGenerator()
        try? tone.start()
        defer { tone.stop() }
        Thread.sleep(forTimeInterval: 0.3)
        return SystemTapProbe().capture(for: duration)
    }

    // MARK: - Microphone

    /// Capture the default input for a moment and report its level.
    ///
    /// Distinct from the permission check: a mic can be authorised, live, and
    /// still too quiet to transcribe well. Observed 2026-08-14 with macOS input
    /// volume at 29/100 — speech peaked at −31 dBFS. Since audio is deleted
    /// immediately after transcription, a whole meeting can be degraded with no
    /// way to redo it (docs/PLAN.md R14b).
    static func probeMicrophone(duration: TimeInterval = 1.5) -> Level? {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return nil }

        let meter = Meter()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            meter.consume(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            return nil
        }
        Thread.sleep(forTimeInterval: duration)
        engine.stop()
        input.removeTap(onBus: 0)
        return meter.level
    }
}

/// Accumulates peak and non-zero counts from audio buffers. Written on the
/// audio thread, read on the caller's thread only after capture has stopped.
final class Meter: @unchecked Sendable {
    private var peak: Float = 0
    private var nonZero = 0
    private var total = 0

    func consumeSample(_ magnitude: Float) {
        total += 1
        if magnitude > 0 { nonZero += 1 }
        if magnitude > peak { peak = magnitude }
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channels[channel]
            for frame in 0..<frames { consumeSample(abs(samples[frame])) }
        }
    }

    func consumeRaw(_ samples: UnsafePointer<Float>, count: Int) {
        for i in 0..<count { consumeSample(abs(samples[i])) }
    }

    var level: AudioProbe.Level {
        AudioProbe.Level(
            peak: peak,
            nonZeroFraction: total > 0 ? Double(nonZero) / Double(total) : 0
        )
    }
}

/// A quiet sine through the default output, so the system tap has something to
/// capture. Without it, silence is ambiguous: unauthorised tap or nothing playing?
private final class ToneGenerator {
    private let engine = AVAudioEngine()
    nonisolated(unsafe) private static var phase: Float = 0

    func start(frequency: Float = 440, amplitude: Float = 0.15) throws {
        let format = engine.outputNode.inputFormat(forBus: 0)
        let increment = 2 * Float.pi * frequency / Float(format.sampleRate)
        let node = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let value = sin(Self.phase) * amplitude
                Self.phase += increment
                if Self.phase > 2 * .pi { Self.phase -= 2 * .pi }
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    data.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        try engine.start()
    }

    func stop() { engine.stop() }
}

/// Minimal one-shot system tap used only for diagnostics. The real recorder is
/// SystemAudioRecorder; this exists so `doctor` can measure without writing a file.
private final class SystemTapProbe {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "io.github.sylvainlafitte.plume.doctor-tap")
    private let meter = Meter()

    func capture(for duration: TimeInterval) -> AudioProbe.Level? {
        defer { cleanup() }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "plume doctor tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &newTap) == noErr else { return nil }
        tapID = newTap

        let uid = "io.github.sylvainlafitte.plume.doctor-aggregate-\(UUID().uuidString)"
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "plume doctor",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(config as CFDictionary, &device) == noErr
        else { return nil }
        aggregateID = device

        var proc: AudioDeviceIOProcID?
        let meter = self.meter
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) {
            _, inInputData, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.assumingMemoryBound(to: Float.self)
                meter.consumeRaw(samples, count: count)
            }
        }
        guard status == noErr, let proc else { return nil }
        procID = proc
        guard AudioDeviceStart(aggregateID, proc) == noErr else { return nil }

        Thread.sleep(forTimeInterval: duration)
        AudioDeviceStop(aggregateID, proc)
        return meter.level
    }

    private func cleanup() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    }
}
