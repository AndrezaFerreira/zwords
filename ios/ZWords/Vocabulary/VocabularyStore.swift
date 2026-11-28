import Foundation
import SwiftData

/// Saves tapped words with their context, merging repeated words into a single entry.
@MainActor
final class VocabularyStore: ObservableObject {
    typealias Translate = @MainActor (String) async -> String?
    typealias Explain = @MainActor (_ word: String, _ offset: Int?, _ sentence: String, _ translation: String?) async -> String?

    /// Lowercased forms/lemmas already in the library (used to highlight captions).
    @Published private(set) var savedForms: Set<String> = []
    /// Last saved word, for the confirmation toast.
    @Published private(set) var lastSaved: (word: String, serial: Int)?

    let context: ModelContext
    private let translate: Translate
    private let explain: Explain
    private var serial = 0
    private var enriching = false

    init(context: ModelContext, translate: @escaping Translate, explain: @escaping Explain) {
        self.context = context
        self.translate = translate
        self.explain = explain
        reloadForms()
    }

    func isSaved(_ word: String) -> Bool {
        savedForms.contains(word.lowercased())
    }

    /// One-tap save. Never asks for confirmation; enrichment happens afterwards.
    @discardableResult
    func save(word rawWord: String, offset: Int?, sentence rawSentence: String, enrich: Bool = true) -> VocabWord? {
        let form = Tokenizer.normalize(rawWord).trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = rawSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !form.isEmpty, !sentence.isEmpty else { return nil }

        let key = Lemmatizer.lemma(of: form, at: offset, in: sentence)
        let entry: VocabWord
        if let existing = fetchWord(key: key) {
            entry = existing
        } else {
            entry = VocabWord(key: key, headword: key == "i" ? "I" : key)
            context.insert(entry)
        }
        entry.updatedAt = .now

        var newContext: WordContext?
        if !entry.contexts.contains(where: { $0.sentence == sentence }) {
            let item = WordContext(form: form, sentence: sentence)
            context.insert(item)
            item.word = entry
            newContext = item
        }
        try? context.save()

        savedForms.insert(form.lowercased())
        savedForms.insert(key)
        serial += 1
        lastSaved = (form, serial)

        if enrich, newContext != nil {
            Task { await enrichPending() }
        }
        return entry
    }

    /// Fills in translations and meanings that are still missing
    /// (also retries entries saved while translation was unavailable).
    func enrichPending() async {
        guard !enriching else { return }
        enriching = true
        defer { enriching = false }
        var round = 0
        while round < 3 {
            round += 1
            let descriptor = FetchDescriptor<WordContext>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            let pending = ((try? context.fetch(descriptor)) ?? []).filter(\.needsEnrichment)
            if pending.isEmpty { return }
            var progressed = false
            for item in pending {
                if item.isDeleted { continue }
                if item.sentenceTranslation.isEmpty, let translated = await translate(item.sentence) {
                    item.sentenceTranslation = translated
                    progressed = true
                }
                if item.isDeleted { continue }
                if item.meaning.isEmpty {
                    let offset = Lemmatizer.range(of: item.form, at: nil, in: item.sentence)
                        .map { item.sentence.utf16.distance(from: item.sentence.startIndex, to: $0.lowerBound) }
                    let translation = item.sentenceTranslation.isEmpty ? nil : item.sentenceTranslation
                    if let meaning = await explain(item.form, offset, item.sentence, translation) {
                        item.meaning = meaning
                        progressed = true
                    }
                }
                try? context.save()
            }
            if !progressed { return }
        }
    }

    func delete(_ word: VocabWord) {
        context.delete(word)
        try? context.save()
        reloadForms()
    }

    func delete(_ item: WordContext) {
        let parent = item.word
        context.delete(item)
        if let parent, parent.contexts.filter({ !$0.isDeleted && $0 != item }).isEmpty {
            context.delete(parent)
        }
        try? context.save()
        reloadForms()
    }

    /// Simple spaced repetition (Leitner boxes).
    func review(_ word: VocabWord, remembered: Bool, now: Date = .now) {
        let intervals: [TimeInterval] = [0, 1, 3, 7, 16, 35].map { $0 * 86_400 }
        if remembered {
            word.reviewBox = min(word.reviewBox + 1, intervals.count - 1)
            word.nextReview = now.addingTimeInterval(intervals[word.reviewBox])
        } else {
            word.reviewBox = 0
            word.nextReview = now.addingTimeInterval(10 * 60)
        }
        try? context.save()
    }

    func reloadForms() {
        let words = (try? context.fetch(FetchDescriptor<VocabWord>())) ?? []
        var forms: Set<String> = []
        for word in words {
            forms.insert(word.key)
            for item in word.contexts { forms.insert(item.form.lowercased()) }
        }
        savedForms = forms
    }

    func fetchWord(key: String) -> VocabWord? {
        var descriptor = FetchDescriptor<VocabWord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
