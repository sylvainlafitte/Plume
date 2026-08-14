import AVFoundation
import CoreAudio
import Foundation

/// Captured-signal statistics. Written from the IOProc thread, read on the main thread
/// only *after* `AudioDeviceStop` has returned — which is the happens-before edge that
/// makes the unsynchronised access safe. Do not read these while capture is running.
nonisolated(unsafe) private var totalSamples = 0
nonisolated(unsafe) private var nonZeroSamples = 0
nonisolated(unsafe) private var peakAmplitude: Float = 0
nonisolated(unsafe) private var ioProcCallbacks = 0

struct ProbeResult {
    var tapCreated = false
    var aggregateCreated = false
    var ioProcStarted = false
    var streamDescription = ""
    var callbacks = 0
    var totalSamples = 0
    var nonZeroSamples = 0
    var peakAmplitude: Float = 0

    /// The whole point of the spike. Every other field can look perfectly healthy
    /// while this is false — that is exactly the failure mode quill#54 documented.
    var capturedRealAudio: Bool { nonZeroSamples > 0 && peakAmplitude > 0.0001 }

    var peakDBFS: String {
        peakAmplitude > 0 ? String(format: "%.1f dBFS", 20 * log10(peakAmplitude)) : "-inf dBFS"
    }

    var nonZeroPercent: String {
        totalSamples > 0
            ? String(format: "%.1f%%", Double(nonZeroSamples) / Double(totalSamples) * 100)
            : "n/a"
    }
}

enum ProbeError: Error, CustomStringConvertible {
    case tapCreationFailed(OSStatus)
    case formatUnavailable(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcFailed(OSStatus)
    case startFailed(OSStatus)

    var description: String {
        switch self {
        case .tapCreationFailed(let s): return "AudioHardwareCreateProcessTap failed: \(s)"
        case .formatUnavailable(let s): return "kAudioTapPropertyFormat failed: \(s)"
        case .aggregateCreationFailed(let s): return "AudioHardwareCreateAggregateDevice failed: \(s)"
        case .ioProcFailed(let s): return "AudioDeviceCreateIOProcIDWithBlock failed: \(s)"
        case .startFailed(let s): return "AudioDeviceStart failed: \(s)"
        }
    }
}

/// Builds a global system-audio tap the same way quill's SystemAudioRecorder does,
/// captures for `duration`, and reports whether any non-zero sample ever arrived.
final class SystemAudioProbe {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.plume.spike.system-tap")

    func run(duration: TimeInterval) throws -> ProbeResult {
        var result = ProbeResult()
        totalSamples = 0
        nonZeroSamples = 0
        peakAmplitude = 0
        ioProcCallbacks = 0

        defer { cleanup() }

        // 1. Global tap: empty exclusion list means everything the Mac plays.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "plume spike-a tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr else { throw ProbeError.tapCreationFailed(tapStatus) }
        tapID = newTapID
        result.tapCreated = true

        // 2. Ask the tap what format it will deliver.
        let format = try tapStreamFormat()
        result.streamDescription =
            "\(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) ch, "
            + "\(format.mBitsPerChannel)-bit"

        // 3. Private aggregate device whose only member is the tap.
        aggregateID = try createAggregateDevice(tapUUID: description.uuid.uuidString)
        result.aggregateCreated = true

        // 4. IOProc that just measures what arrives.
        try installIOProc()
        result.ioProcStarted = true

        Thread.sleep(forTimeInterval: duration)

        AudioDeviceStop(aggregateID, ioProcID)
        // AudioDeviceStop has returned: no further callbacks, safe to read.

        result.callbacks = ioProcCallbacks
        result.totalSamples = totalSamples
        result.nonZeroSamples = nonZeroSamples
        result.peakAmplitude = peakAmplitude
        return result
    }

    private func tapStreamFormat() throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr else { throw ProbeError.formatUnavailable(status) }
        return asbd
    }

    private func createAggregateDevice(tapUUID: String) throws -> AudioObjectID {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "plume spike-a aggregate",
            kAudioAggregateDeviceUIDKey: "com.plume.spike.aggregate-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(
            description as CFDictionary, &deviceID)
        guard status == noErr else { throw ProbeError.aggregateCreationFailed(status) }
        return deviceID
    }

    private func installIOProc() throws {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            _, inInputData, _, _, _ in
            ioProcCallbacks += 1

            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inInputData))
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.assumingMemoryBound(to: Float.self)
                for i in 0..<count {
                    let value = abs(samples[i])
                    totalSamples += 1
                    if value > 0 { nonZeroSamples += 1 }
                    if value > peakAmplitude { peakAmplitude = value }
                }
            }
        }
        guard status == noErr, let procID else { throw ProbeError.ioProcFailed(status) }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else { throw ProbeError.startFailed(startStatus) }
    }

    private func cleanup() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
