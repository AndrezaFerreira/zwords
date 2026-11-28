import ReplayKit
import Speech

/// Broadcast Upload Extension: receives the audio of every app that is
/// playing on the iPhone (system-wide) while the broadcast is active,
/// transcribes it on-device and hands the captions to the main app through
/// the shared App Group container.
final class SampleHandler: RPBroadcastSampleHandler {
    private let transcriber = LiveTranscriber()
    private let writer = BroadcastWriter()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .denied || status == .restricted {
            fail("Abra o ZWords e permita o Reconhecimento de Fala em Ajustes.")
            return
        }
        guard AppGroup.containerURL != nil else {
            fail("Não foi possível acessar o App Group do ZWords. Reinstale o app.")
            return
        }
        transcriber.onUpdate = { [writer] update in
            writer.update(id: update.segmentID, text: update.text, isFinal: update.isFinal)
        }
        transcriber.onError = { [writer] message in
            writer.setStatus(.running, message: message)
        }
        writer.start()
        transcriber.start()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        // Only app audio is used; video frames are ignored right away to save energy.
        guard sampleBufferType == .audioApp,
              let buffer = SampleBufferAudio.monoBuffer(from: sampleBuffer) else { return }
        transcriber.append(buffer)
    }

    override func broadcastPaused() {
        transcriber.stop()
    }

    override func broadcastResumed() {
        transcriber.start()
    }

    override func broadcastFinished() {
        transcriber.stop()
        writer.setStatus(.stopped, message: nil, synchronously: true)
    }

    private func fail(_ message: String) {
        writer.setStatus(.error, message: message, synchronously: true)
        let error = NSError(domain: "ZWords", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        finishBroadcastWithError(error)
    }
}

/// Keeps the latest captions in memory and mirrors them to the App Group.
final class BroadcastWriter {
    private let queue = DispatchQueue(label: "zwords.broadcast.writer", qos: .utility)
    private var snapshot = BroadcastSnapshot(sessionID: UUID().uuidString, status: .running,
                                             message: nil, segments: [], updatedAt: Date())
    private var writeScheduled = false
    private var heartbeat: DispatchSourceTimer?

    func start() {
        queue.async { [self] in
            snapshot.status = .running
            flush()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
            timer.setEventHandler { [weak self] in self?.flush() }
            timer.resume()
            heartbeat = timer
        }
    }

    func update(id: Int, text: String, isFinal: Bool) {
        queue.async { [self] in
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = snapshot.segments.lastIndex(where: { $0.id == id }) {
                if trimmed.isEmpty && isFinal {
                    snapshot.segments.remove(at: index)
                } else {
                    snapshot.segments[index].text = trimmed
                    snapshot.segments[index].isFinal = isFinal
                }
            } else if !trimmed.isEmpty {
                snapshot.segments.append(.init(id: id, text: trimmed, isFinal: isFinal))
                if snapshot.segments.count > 40 { snapshot.segments.removeFirst(snapshot.segments.count - 40) }
            }
            snapshot.message = nil
            scheduleWrite()
        }
    }

    func setStatus(_ status: BroadcastSnapshot.Status, message: String?, synchronously: Bool = false) {
        let work = { [self] in
            snapshot.status = status
            snapshot.message = message
            if status != .running {
                heartbeat?.cancel()
                heartbeat = nil
            }
            flush()
        }
        if synchronously { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    private func scheduleWrite() {
        guard !writeScheduled else { return }
        writeScheduled = true
        queue.asyncAfter(deadline: .now() + 0.1) { [self] in
            writeScheduled = false
            flush()
        }
    }

    private func flush() {
        snapshot.updatedAt = Date()
        BroadcastChannel.write(snapshot)
    }
}
