import AVFoundation
import Foundation
import os.lock

/// Records the default input device to a file via AVAudioEngine, encoding AAC
/// mono. Buffers stream straight to disk — nothing is held in memory, so
/// session length is unbounded.
///
/// With voice processing on (off by default, see Config), Apple's echo canceller subtracts
/// speaker playback from the mic so the system track doesn't bleed into the
/// mic track. VoiceProcessingIO is a duplex unit, not an input effect: it
/// needs a rendered output path and one explicit mono client format on both
/// sides, or it silently delivers zeroed buffers (rca-001). A first-second
/// liveness check catches routes where even the correct graph stays silent
/// and restarts capture raw.
/// The `@unchecked Sendable` here is **inherited debt, not a justified assertion**. Quill added
/// it to satisfy one `DispatchQueue.main.async` capture, which disabled checking on the whole
/// class. quill#18 fixed the part that mattered — `file`, `firstBufferAt` and `lastBufferAt` are
/// now behind a lock — but the class-level conformance remains and still hides anything new
/// added here. Removing it means proving every remaining cross-thread field safe; until then,
/// treat any new stored property on this class as suspect. See AGENTS.md.
final class MicRecorder: @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case formatUnsupported(AVAudioFormat)

        var description: String {
            switch self {
            case .engineStartFailed(let e): return "mic engine start failed: \(e)"
            case .fileCreationFailed(let e): return "mic file creation failed: \(e)"
            case .formatUnsupported(let f): return "can't downmix mic format \(f)"
            }
        }
    }

    private var engine = AVAudioEngine()
    private var url: URL?
    private(set) var isRecording = false

    // Thread-safe shared state: accessed from both the main thread and the
    // audio-tap callback (background audio thread) without further sync.
    // Cherry-picked from digimata/quill#18.
    private struct LockedState {
        var file: AVAudioFile?
        var firstBufferAt: Date?
        // Added here rather than as a bare property: quill#2 introduced
        // lastBufferAt independently of quill#18's locking, so upstream writes
        // it from the tap thread and reads it on main unsynchronised — the same
        // race #18 exists to fix.
        var lastBufferAt: Date?
    }
    private let state = OSAllocatedUnfairLock(initialState: LockedState())

    private var file: AVAudioFile? {
        get { state.withLock { $0.file } }
        set { state.withLock { $0.file = newValue } }
    }

    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    private(set) var firstBufferAt: Date? {
        get { state.withLock { $0.firstBufferAt } }
        set { state.withLock { $0.firstBufferAt = newValue } }
    }

    /// Wall-clock time of the most recent captured buffer. When a device
    /// reconfiguration kills the engine, the span from here to the restart is
    /// written as silence so downstream timestamps stay wall-clock aligned.
    private var lastBufferAt: Date? {
        get { state.withLock { $0.lastBufferAt } }
        set { state.withLock { $0.lastBufferAt = newValue } }
    }

    private var configObserver: NSObjectProtocol?
    private var restartPending = false

    // Liveness check state (voice-processing path only). Written from the tap
    // callback, read on main when deciding to fall back. The dispatch to main
    // in fallBackToRaw creates a happens-before, so these need no lock.
    private var livenessFrames = 0
    private var livenessPeak: Float = 0
    private var livenessSettled = false

    /// Start capturing the mic, encoding AAC into `url` (use a .caf extension
    /// — CAF needs no finalization pass, so a crash loses nothing written).
    func start(writingTo url: URL) throws {
        guard !isRecording else { return }
        self.url = url
        try attach(voiceProcessing: Config.micVoiceProcessing())
        isRecording = true
        // A call app (FaceTime, Zoom) grabbing the mic reconfigures the input
        // device and stops the engine mid-session; without this observer the
        // track just ends there — upstream measured a 1.7s mic track on a
        // 19-minute call. Cherry-picked from digimata/quill#2.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, (note.object as? AVAudioEngine) === self.engine else { return }
            self.handleConfigChange()
        }
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        file = nil
        lastBufferAt = nil
    }

    // MARK: -

    /// Build the engine graph, create the AAC file, and start capture. Called
    /// once at start, again (voiceProcessing: false) if the liveness check
    /// trips, and (reusingFile: true) after a device reconfiguration.
    private func attach(voiceProcessing: Bool, reusingFile: Bool = false) throws {
        engine = AVAudioEngine()
        let input = engine.inputNode

        var voice = voiceProcessing
        if voice {
            do {
                try input.setVoiceProcessingEnabled(true)
                // The live voice unit makes macOS treat the session like a
                // call and duck all other audio — meetings played through the
                // speakers would get quieter the moment recording starts.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: mic voice processing unavailable (\(error)) — recording raw mic\n".utf8
                ))
                voice = false
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)

        // One explicit mono client format. With voice processing this is the
        // Voice I/O boundary format on both sides of the duplex unit — never
        // accept the inherited multichannel route format (a 9-channel device
        // yielded digital silence). Raw capture downmixes to the same shape;
        // speech models want one channel anyway.
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }

        if reusingFile, let existing = file {
            // Mid-session restart: keep appending to the open file. The tap
            // converts to the file's original format, so a device that came
            // back at a different sample rate still writes cleanly. Raw path
            // only — during a call the call app owns echo cancellation, and
            // re-engaging VP mid-call is what causes the device fight.
            try installRawTap(
                on: input, inputFormat: inputFormat, monoFormat: existing.processingFormat)
            engine.prepare()
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw RecorderError.engineStartFailed(error)
            }
            return
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: monoFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        do {
            file = try AVAudioFile(
                forWriting: url!,
                settings: settings,
                commonFormat: monoFormat.commonFormat,
                interleaved: monoFormat.isInterleaved
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }

        if voice {
            // Complete the duplex graph: VoiceProcessingIO must render to an
            // output device or the input side never produces audio. The mixer
            // has no sources — nothing is monitored or played — its connection
            // exists solely to give the unit a formatted output path.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: monoFormat)
            livenessFrames = 0
            livenessPeak = 0
            livenessSettled = false
            installVoiceTap(on: input, format: monoFormat)
        } else {
            try installRawTap(on: input, inputFormat: inputFormat, monoFormat: monoFormat)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            file = nil
            throw RecorderError.engineStartFailed(error)
        }

        let report = "mic: voiceProcessing=\(input.isVoiceProcessingEnabled) "
            + "input=\(input.outputFormat(forBus: 0)) tap=\(monoFormat)\n"
        FileHandle.standardError.write(Data(report.utf8))
    }

    /// Voice-processing path: the unit converts to the mono client format
    /// itself, so tapped buffers write straight to the file. Tracks signal
    /// peak over the first second — an unsupported route (device pair, macOS
    /// AUVPAggregate defects) delivers callbacks full of digital zeros, and
    /// the only recovery is restarting raw.
    private func installVoiceTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        let checkFrames = Int(format.sampleRate)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let file = self.file else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            self.lastBufferAt = Date()

            if !self.livenessSettled {
                let frames = Int(buffer.frameLength)
                if let data = buffer.floatChannelData?[0] {
                    for i in 0..<frames {
                        self.livenessPeak = max(self.livenessPeak, abs(data[i]))
                    }
                }
                self.livenessFrames += frames
                if self.livenessFrames >= checkFrames {
                    self.livenessSettled = true
                    if self.livenessPeak == 0 {
                        DispatchQueue.main.async { self.fallBackToRaw() }
                        return
                    }
                }
            }

            do {
                try file.write(from: buffer)
            } catch {
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
            }
        }
    }

    /// Raw path: tap at the device's native format and downmix to mono. Same
    /// sample rate on both sides, so the one-shot convert applies.
    private func installRawTap(
        on input: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        monoFormat: AVAudioFormat
    ) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: monoFormat) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }
        let sameRate = inputFormat.sampleRate == monoFormat.sampleRate
        let ratio = monoFormat.sampleRate / inputFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let file = self.file else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            self.lastBufferAt = Date()
            let capacity = AVAudioFrameCount(Double(buffer.frameCapacity) * ratio) + 64
            guard let mono = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: capacity
            ) else { return }
            do {
                if sameRate {
                    try converter.convert(to: mono, from: buffer)
                } else {
                    // Post-reconfigure the device can come back at a new rate;
                    // the one-shot convert only handles equal rates.
                    var fed = false
                    var convertError: NSError?
                    converter.convert(to: mono, error: &convertError) { _, outStatus in
                        if fed {
                            outStatus.pointee = .noDataNow
                            return nil
                        }
                        fed = true
                        outStatus.pointee = .haveData
                        return buffer
                    }
                    if let convertError { throw convertError }
                }
                try file.write(from: mono)
            } catch {
                FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
            }
        }
    }

    // MARK: - Device reconfiguration recovery (digimata/quill#2)

    /// Another process reconfigured the input device (typically a call app
    /// engaging voice processing) and the engine stopped. Debounce briefly —
    /// reconfiguration storms post several notifications — then restart.
    private func handleConfigChange() {
        guard isRecording, !restartPending else { return }
        restartPending = true
        FileHandle.standardError.write(Data(
            "mic: input device reconfigured (call app?) — restarting capture\n".utf8
        ))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.restartCapture()
        }
    }

    private func restartCapture() {
        restartPending = false
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        padGapWithSilence()
        do {
            try attach(voiceProcessing: false, reusingFile: true)
        } catch {
            FileHandle.standardError.write(Data(
                "mic restart failed: \(error) — retrying in 2s\n".utf8
            ))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, self.isRecording else { return }
                self.restartCapture()
            }
        }
    }

    /// Write zeroed frames covering the dead span so the track's duration
    /// stays wall-clock true and transcript timestamps don't drift.
    private func padGapWithSilence() {
        guard let file, let last = lastBufferAt else { return }
        let gap = Date().timeIntervalSince(last)
        guard gap > 0.05 else { return }
        let format = file.processingFormat
        var remaining = AVAudioFrameCount(gap * format.sampleRate)
        let chunk = AVAudioFrameCount(format.sampleRate)
        while remaining > 0 {
            let n = min(remaining, chunk)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return }
            buf.frameLength = n
            if let data = buf.floatChannelData?[0] {
                data.update(repeating: 0, count: Int(n))
            }
            try? file.write(from: buf)
            remaining -= n
        }
    }

    /// The voice-processing route delivered a full second of digital silence:
    /// tear the engine down and restart raw, discarding the silent prefix so
    /// the track's timestamps start at real audio.
    private func fallBackToRaw() {
        guard isRecording else { return }
        FileHandle.standardError.write(Data(
            "warning: voice processing delivered silence — restarting mic raw\n".utf8
        ))
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        file = nil
        firstBufferAt = nil
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            try attach(voiceProcessing: false)
        } catch {
            FileHandle.standardError.write(Data(
                "mic raw fallback failed: \(error) — session continues without mic track\n".utf8
            ))
            file = nil
        }
    }
}
