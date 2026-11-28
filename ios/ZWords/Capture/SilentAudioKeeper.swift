import AVFoundation

/// While only the system-wide (broadcast) capture is running, iOS would
/// suspend the app in the background and the floating captions would freeze.
/// A silent, mixable audio stream keeps the app awake at negligible cost.
final class SilentAudioKeeper {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var configured = false

    func start() {
        guard !engine.isRunning else { return }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050) else { return }
        buffer.frameLength = buffer.frameCapacity
        if let data = buffer.floatChannelData?[0] {
            data.initialize(repeating: 0, count: Int(buffer.frameLength))
        }
        if !configured {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            configured = true
        }
        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
        } catch {
            engine.stop()
        }
    }

    func stop() {
        guard engine.isRunning else { return }
        player.stop()
        engine.stop()
    }
}
