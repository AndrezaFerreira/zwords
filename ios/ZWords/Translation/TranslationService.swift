import Foundation
import SwiftUI
import Translation

/// On-device English → Brazilian Portuguese translation using Apple's free
/// Translation framework. A single long-lived session (provided by the
/// `.translationTask` modifier on the root view) serves a queue of requests.
@MainActor
final class TranslationService: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    @Published private(set) var isReady = false
    @Published private(set) var problem: String?

    private struct Job {
        let text: String
        let completion: (String?) -> Void
    }

    private var cache: [String: String] = [:]
    private var queue: [Job] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private var failed = false

    func activate() {
        guard configuration == nil else { return }
        configuration = TranslationSession.Configuration(
            source: Locale.Language(identifier: "en"),
            target: Locale.Language(identifier: "pt-BR"))
    }

    /// Asks the system again (e.g. to download the language pack).
    func retry() {
        failed = false
        problem = nil
        if configuration == nil { activate() } else { configuration?.invalidate() }
    }

    func cached(_ text: String) -> String? {
        cache[text.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    func translate(_ text: String) async -> String? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if let hit = cache[key] { return hit }
        if failed { return nil }
        let result: String? = await withCheckedContinuation { continuation in
            queue.append(Job(text: key) { continuation.resume(returning: $0) })
            wake()
        }
        if let result {
            if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
            cache[key] = result
        }
        return result
    }

    /// Runs for as long as the root view is alive.
    func serve(_ session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
            isReady = true
            failed = false
            problem = nil
        } catch {
            isReady = false
            failed = true
            problem = "Tradução indisponível. Toque para baixar os idiomas (Inglês e Português) em Ajustes › Apps › Traduzir."
            drain()
            return
        }

        while !Task.isCancelled {
            if queue.isEmpty {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        if queue.isEmpty && !Task.isCancelled { waiter = continuation } else { continuation.resume() }
                    }
                } onCancel: {
                    Task { @MainActor in self.wake() }
                }
                continue
            }
            let job = queue.removeFirst()
            do {
                let response = try await session.translate(job.text)
                job.completion(response.targetText)
            } catch {
                job.completion(nil)
            }
        }
        isReady = false
        drain()
    }

    private func wake() {
        let current = waiter
        waiter = nil
        current?.resume()
    }

    private func drain() {
        let jobs = queue
        queue.removeAll()
        jobs.forEach { $0.completion(nil) }
    }
}
