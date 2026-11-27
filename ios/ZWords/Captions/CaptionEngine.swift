import AVFoundation
import Foundation
import Speech
import SwiftUI

enum DisplayMode: String, CaseIterable, Identifiable {
    case english, portuguese, bilingual
    var id: String { rawValue }
    var label: String {
        switch self {
        case .english: "EN"
        case .portuguese: "PT"
        case .bilingual: "EN + PT"
        }
    }
}

/// One sentence of caption.
struct CaptionLine: Identifiable, Equatable {
    let id: String
    var text: String
    var isFinal: Bool
    var chunks: [Chunk]
}

/// Orchestrates capture → transcription → translation → captions (in-app and PiP).
@MainActor
final class CaptionEngine: ObservableObject {
    @Published private(set) var lines: [CaptionLine] = []
    @Published private(set) var translations: [String: String] = [:]   // line id → pt-BR
    @Published private(set) var isMicRunning = false
    @Published private(set) var isDeviceAudioActive = false
    @Published var notice: String?

    var mode: DisplayMode = .bilingual {
        didSet { if oldValue != mode { refreshPiP() } }
    }

    let pip = CaptionPiP()

    private struct Segment {
        let key: String
        var text: String
        var isFinal: Bool
        var lines: [CaptionLine]
    }

    private let translator: TranslationService
    private let mic = MicCapture()
    private var micTranscriber: LiveTranscriber?
    private let receiver = BroadcastReceiver()
    private let keeper = SilentAudioKeeper()
    private var segments: [Segment] = []
    private var translatedSource: [String: String] = [:]   // line id → text that was translated
    private var liveTranslationTask: Task<Void, Never>?
    private var micSession = 0
    private var stalenessTimer: Timer?
    private var prepared = false
    private let maxSegments = 160

    init(translator: TranslationService) {
        self.translator = translator
        pip.isActiveCapture = { [weak self] in
            MainActor.assumeIsolated { (self?.isMicRunning ?? false) || (self?.isDeviceAudioActive ?? false) }
        }
        pip.onSetPlaying = { [weak self] playing in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !playing && self.isMicRunning { self.stopMic() }
                if playing && !self.isMicRunning && !self.isDeviceAudioActive { Task { await self.toggleMic() } }
            }
        }
    }

    // MARK: - Lifecycle

    func prepare() async {
        guard !prepared else { return }
        prepared = true
        pip.setup()
        refreshPiP()
        receiver.onSnapshot = { [weak self] snapshot in self?.handle(snapshot: snapshot) }
        receiver.start()
        stalenessTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.receiver.read() }
        }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await LiveTranscriber.requestAuthorization()
        }
    }

    func clear() {
        segments.removeAll()
        lines.removeAll()
        translations.removeAll()
        translatedSource.removeAll()
        refreshPiP()
    }

    // MARK: - Microphone

    func toggleMic() async {
        if isMicRunning {
            stopMic()
            return
        }
        guard await ensurePermissions() else { return }
        do {
            try AudioSessionManager.activate(recording: true)
            micSession += 1
            let session = micSession
            let transcriber = LiveTranscriber()
            transcriber.onUpdate = { [weak self] update in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.apply(key: "m\(session)-\(update.segmentID)", text: update.text, isFinal: update.isFinal)
                    }
                }
            }
            transcriber.onError = { [weak self] message in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.notice = message } }
            }
            keeper.stop()
            transcriber.start()
            try mic.start { buffer in transcriber.append(buffer) }
            micTranscriber = transcriber
            isMicRunning = true
            notice = transcriber.supportsOnDeviceRecognition ? nil
                : "Este iPhone não suporta transcrição offline: a Apple processará o áudio on-line."
        } catch {
            micTranscriber?.stop()
            micTranscriber = nil
            notice = "Não foi possível acessar o microfone."
        }
        updateKeepAlive()
        pip.invalidatePlaybackState()
    }

    func stopMic() {
        mic.stop()
        micTranscriber?.stop()
        micTranscriber = nil
        isMicRunning = false
        updateKeepAlive()
        pip.invalidatePlaybackState()
    }

    private func ensurePermissions() async -> Bool {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined { status = await LiveTranscriber.requestAuthorization() }
        guard status == .authorized else {
            notice = "Permita o Reconhecimento de Fala em Ajustes › Apps › ZWords."
            return false
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            notice = "Permita o acesso ao Microfone em Ajustes › Apps › ZWords."
            return false
        }
        return true
    }

    // MARK: - iPhone audio (broadcast extension)

    private func handle(snapshot: BroadcastSnapshot) {
        let age = Date().timeIntervalSince(snapshot.updatedAt)
        let active = snapshot.status == .running && age < 8
        if active != isDeviceAudioActive {
            isDeviceAudioActive = active
            updateKeepAlive()
            pip.invalidatePlaybackState()
        }
        if age < 60, let message = snapshot.message, snapshot.status != .stopped {
            notice = message
        }
        // Ignore leftovers of old sessions.
        guard age < 30 * 60 else { return }
        let prefix = "d" + snapshot.sessionID.prefix(8)
        for segment in snapshot.segments {
            apply(key: "\(prefix)-\(segment.id)", text: segment.text, isFinal: segment.isFinal)
        }
    }

    private func updateKeepAlive() {
        if isDeviceAudioActive && !isMicRunning {
            try? AudioSessionManager.activate(recording: false)
            keeper.start()
        } else {
            keeper.stop()
            if !isMicRunning && !isDeviceAudioActive { AudioSessionManager.deactivate() }
        }
    }

    // MARK: - Captions

    func apply(key: String, text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = segments.lastIndex(where: { $0.key == key }) {
            if segments[index].text == trimmed && segments[index].isFinal == isFinal { return }
            if trimmed.isEmpty && isFinal {
                segments.remove(at: index)
            } else {
                segments[index].text = trimmed
                segments[index].isFinal = isFinal
                segments[index].lines = makeLines(key: key, text: trimmed, isFinal: isFinal)
                scheduleTranslation(for: segments[index].lines)
            }
        } else {
            guard !trimmed.isEmpty else { return }
            let newLines = makeLines(key: key, text: trimmed, isFinal: isFinal)
            segments.append(Segment(key: key, text: trimmed, isFinal: isFinal, lines: newLines))
            if segments.count > maxSegments {
                let removed = segments.prefix(segments.count - maxSegments)
                for line in removed.flatMap(\.lines) {
                    translations[line.id] = nil
                    translatedSource[line.id] = nil
                }
                segments.removeFirst(segments.count - maxSegments)
            }
            scheduleTranslation(for: newLines)
        }
        lines = segments.flatMap(\.lines)
        refreshPiP()
    }

    private func makeLines(key: String, text: String, isFinal: Bool) -> [CaptionLine] {
        let sentences = Tokenizer.sentences(in: text)
        return sentences.enumerated().map { index, sentence in
            CaptionLine(id: "\(key)#\(index)", text: sentence,
                        isFinal: isFinal || index < sentences.count - 1,
                        chunks: Tokenizer.chunks(in: sentence))
        }
    }

    private func scheduleTranslation(for newLines: [CaptionLine]) {
        for line in newLines where translatedSource[line.id] != line.text {
            if let hit = translator.cached(line.text) {
                setTranslation(hit, for: line)
            } else if line.isFinal {
                Task { await translate(line) }
            } else {
                // Live (still changing) sentence: debounce to save energy.
                liveTranslationTask?.cancel()
                liveTranslationTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    await self?.translate(line)
                }
            }
        }
    }

    private func translate(_ line: CaptionLine) async {
        guard let result = await translator.translate(line.text) else { return }
        // Only apply if the line still exists (it may have been revised).
        guard let current = lines.last(where: { $0.id == line.id }),
              current.text == line.text || translatedSource[line.id] == nil else { return }
        setTranslation(result, for: line)
    }

    private func setTranslation(_ text: String, for line: CaptionLine) {
        translations[line.id] = text
        translatedSource[line.id] = line.text
        refreshPiP()
    }

    // MARK: - Picture in Picture

    func togglePiP() {
        pip.toggle()
    }

    private func refreshPiP() {
        guard let last = lines.last else {
            pip.show(.init(primary: "ZWords", secondary: "Aguardando fala em inglês…"))
            return
        }
        let english = last.text
        let portuguese = translations[last.id]
        switch mode {
        case .english:
            pip.show(.init(primary: english, secondary: nil))
        case .portuguese:
            pip.show(.init(primary: portuguese ?? english, secondary: nil))
        case .bilingual:
            pip.show(.init(primary: english, secondary: portuguese ?? " "))
        }
    }
}
