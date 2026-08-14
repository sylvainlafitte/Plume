import AVFoundation
import Foundation

/// Only touched by the render thread.
nonisolated(unsafe) private var phase: Float = 0

/// Plays a quiet sine tone through the default output device, so the system tap has
/// something to capture. Without this the probe can't distinguish "tap is unauthorised"
/// from "nothing was playing".
final class ToneGenerator {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    func start(frequency: Float = 440, amplitude: Float = 0.2) throws {
        let output = engine.outputNode
        let outputFormat = output.inputFormat(forBus: 0)
        let sampleRate = Float(outputFormat.sampleRate)
        let increment = 2 * Float.pi * frequency / sampleRate

        let node = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let value = sin(phase) * amplitude
                phase += increment
                if phase > 2 * .pi { phase -= 2 * .pi }
                for buffer in buffers {
                    guard let data = buffer.mData else { continue }
                    data.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
            return noErr
        }

        engine.attach(node)
        // Connect with the output's own format so we don't fight the device's channel layout.
        engine.connect(node, to: engine.mainMixerNode, format: outputFormat)
        sourceNode = node

        try engine.start()
    }

    func stop() {
        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
            self.sourceNode = nil
        }
    }
}
