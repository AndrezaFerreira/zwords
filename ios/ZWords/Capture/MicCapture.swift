import AVFoundation

/// Streams microphone audio (conversations, classes, talks, ambient sound).
final class MicCapture {
    private let engine = AVAudioEngine()
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private(set) var isRunning = false

    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        self.onBuffer = onBuffer
        try startEngine()
        isRunning = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                self?.restart()
            },
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                self?.restart()
            },
        ]
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        onBuffer = nil
    }

    private func startEngine() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "ZWords", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Microfone indisponível."])
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    private func restart() {
        guard isRunning else { return }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(true)
        try? startEngine()
    }
}
