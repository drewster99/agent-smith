import AVFoundation
import os

nonisolated private let chimeLogger = Logger(subsystem: "com.agentsmith", category: "LaunchChime")

/// Plays a short, synthesized arpeggio at app launch.
///
/// The chime is generated in-process so no bundled audio asset is required.
/// It's a quick C-major arpeggio (C5 → E5 → G5 → C6) with overlapping
/// exponential decays and a touch of harmonic sparkle, scaled to a gentle
/// peak amplitude so it never feels jarring.
@MainActor
final class LaunchChime {
    static let shared = LaunchChime()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var hasPlayed = false

    private init() {
        engine.attach(player)
    }

    /// Plays the chime exactly once per process. Subsequent calls are no-ops.
    func playOnce() {
        guard !hasPlayed else { return }
        hasPlayed = true

        let sampleRate: Double = 44_100
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        ) else {
            chimeLogger.error("Could not build AVAudioFormat for chime")
            return
        }

        engine.connect(player, to: engine.mainMixerNode, format: format)

        guard let buffer = makeChimeBuffer(format: format, sampleRate: sampleRate) else {
            chimeLogger.error("Could not allocate PCM buffer for chime")
            return
        }

        do {
            try engine.start()
        } catch {
            chimeLogger.error("AVAudioEngine failed to start: \(error.localizedDescription, privacy: .public)")
            return
        }

        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.player.stop()
                self.engine.stop()
            }
        }
        player.play()
    }

    private func makeChimeBuffer(format: AVAudioFormat, sampleRate: Double) -> AVAudioPCMBuffer? {
        // C-major arpeggio. Overlapping note tails fuse into a final chord.
        let notes: [Double] = [523.25, 659.25, 783.99, 1046.50]
        let noteSpacing: Double = 0.10
        let tail: Double = 0.55
        let totalDuration = noteSpacing * Double(notes.count - 1) + tail
        let frameCount = AVAudioFrameCount(totalDuration * sampleRate)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        guard let channels = buffer.floatChannelData else { return nil }
        let left = channels[0]
        let right = channels[1]

        let attack: Double = 0.006
        let decayTau: Double = 0.32
        let amplitude: Double = 0.16

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate
            var sample: Double = 0

            for (idx, freq) in notes.enumerated() {
                let noteStart = Double(idx) * noteSpacing
                guard t >= noteStart else { continue }
                let nt = t - noteStart

                let env: Double
                if nt < attack {
                    env = nt / attack
                } else {
                    env = exp(-(nt - attack) / decayTau)
                }

                let phase = 2 * .pi * freq * t
                let voice =
                    sin(phase) * 0.78 +
                    sin(phase * 2) * 0.16 +
                    sin(phase * 3) * 0.05
                sample += env * voice
            }

            // Soft master fade-out over the last ~120ms so the buffer ends silently.
            let fadeStart = totalDuration - 0.12
            if t > fadeStart {
                let f = max(0, (totalDuration - t) / 0.12)
                sample *= f
            }

            let value = Float(sample * amplitude)
            left[frame] = value
            right[frame] = value
        }

        return buffer
    }
}
