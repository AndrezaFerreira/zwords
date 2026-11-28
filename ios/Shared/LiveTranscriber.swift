import AVFoundation
import Foundation
import Speech

/// Continuous, low-latency English speech-to-text built on Apple's on-device
/// speech recognizer. Audio is split into short "segments" at natural pauses
/// so captions behave like movie subtitles, and so each recognition request
/// stays short (lower latency, lower memory, no request-length limits).
final class LiveTranscriber {
    struct Update {
        let segmentID: Int
        let text: String
        let isFinal: Bool
    }

    /// Called on a private queue.
    var onUpdate: ((Update) -> Void)?
    /// Called on a private queue with a user-facing (Portuguese) message.
    var onError: ((String) -> Void)?

    /// Silence (no change in the hypothesis) that closes a caption segment.
    var pauseToCommit: TimeInterval = 1.0
    /// Hard limit for a single segment during non-stop speech.
    var maxSegmentDuration: TimeInterval = 30

    private let queue = DispatchQueue(label: "zwords.transcriber", qos: .userInitiated)
    private let recognizer: SFSpeechRecognizer?
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?   // written on `queue`, read under `lock`
    private var tasks: [Int: SFSpeechRecognitionTask] = [:]
    private var lastText: [Int: String] = [:]
    private var segmentID = 0
    private var currentText = ""
    private var lastChange = Date()
    private var segmentStart = Date()
    private var running = false
    private var timer: DispatchSourceTimer?
    private var retryAfter = Date.distantPast
    private var reportedUnavailable = false

    init(localeIdentifier: String = "en-US") {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
        recognizer?.defaultTaskHint = .dictation
    }

    var supportsOnDeviceRecognition: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            beginSegment()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.2, repeating: 0.2, leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            guard running else { return }
            running = false
            timer?.cancel()
            timer = nil
            endCurrentSegment()
        }
    }

    /// Thread-safe; may be called from a real-time audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        lock.unlock()
        current?.append(buffer)
    }

    // MARK: - Segments (all on `queue`)

    private func beginSegment() {
        guard running, let recognizer else { return }
        guard recognizer.isAvailable else {
            retryAfter = Date().addingTimeInterval(2)
            if !reportedUnavailable {
                reportedUnavailable = true
                onError?("O reconhecimento de fala está indisponível no momento. Tentando novamente…")
            }
            return
        }
        reportedUnavailable = false
        segmentID += 1
        let id = segmentID
        let newRequest = SFSpeechAudioBufferRecognitionRequest()
        newRequest.shouldReportPartialResults = true
        newRequest.addsPunctuation = true
        newRequest.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            newRequest.requiresOnDeviceRecognition = true
        }
        currentText = ""
        segmentStart = Date()
        lastChange = segmentStart

        let task = recognizer.recognitionTask(with: newRequest) { [weak self] result, error in
            guard let self else { return }
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            self.queue.async { self.handle(id: id, text: text, isFinal: isFinal, failed: error != nil && result == nil) }
        }
        tasks[id] = task
        lock.lock()
        request = newRequest
        lock.unlock()
    }

    private func endCurrentSegment() {
        lock.lock()
        let finished = request
        request = nil
        lock.unlock()
        guard let finished else { return }
        finished.endAudio()
        if currentText.isEmpty, let task = tasks[segmentID] {
            // Nothing was said: drop the request instead of waiting for a result.
            task.cancel()
            tasks[segmentID] = nil
        }
    }

    private func handle(id: Int, text: String?, isFinal: Bool, failed: Bool) {
        if let text {
            let isCurrent = id == segmentID && request != nil
            if isCurrent && !isFinal && text != currentText {
                currentText = text
                lastChange = Date()
            }
            if isFinal {
                tasks[id] = nil
                lastText[id] = nil
            } else {
                lastText[id] = text
            }
            if !text.isEmpty || isFinal {
                onUpdate?(Update(segmentID: id, text: text, isFinal: isFinal))
            }
            if isFinal && isCurrent && running {
                // The recognizer closed the segment by itself; keep listening.
                endCurrentSegment()
                beginSegment()
            }
            return
        }

        guard failed else { return }
        tasks[id] = nil
        // Close the caption with the best text we have (or remove it if empty).
        let best = lastText.removeValue(forKey: id) ?? ""
        onUpdate?(Update(segmentID: id, text: best, isFinal: true))
        if id == segmentID && request != nil {
            lock.lock()
            request = nil
            lock.unlock()
            retryAfter = Date().addingTimeInterval(0.3)
        }
    }

    private func tick() {
        guard running else { return }
        if request == nil {
            if Date() >= retryAfter { beginSegment() }
            return
        }
        let now = Date()
        if !currentText.isEmpty {
            if now.timeIntervalSince(lastChange) >= pauseToCommit
                || now.timeIntervalSince(segmentStart) >= maxSegmentDuration {
                endCurrentSegment()
                beginSegment()
            }
        } else if now.timeIntervalSince(segmentStart) >= 50 {
            endCurrentSegment()
            beginSegment()
        }
    }
}
