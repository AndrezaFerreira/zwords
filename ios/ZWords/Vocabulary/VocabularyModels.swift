import Foundation
import SwiftData

/// One entry of the personal vocabulary library (deduplicated by dictionary form).
@Model
final class VocabWord {
    @Attribute(.unique) var key: String
    var headword: String
    var createdAt: Date
    var updatedAt: Date
    var reviewBox: Int = 0
    var nextReview: Date
    @Relationship(deleteRule: .cascade, inverse: \WordContext.word)
    var contexts: [WordContext] = []

    init(key: String, headword: String, date: Date = .now) {
        self.key = key
        self.headword = headword
        self.createdAt = date
        self.updatedAt = date
        self.nextReview = date
    }

    var sortedContexts: [WordContext] {
        contexts.sorted { $0.createdAt > $1.createdAt }
    }

    /// Meaning shown in lists: the most recent one that is already available.
    var latestMeaning: String {
        sortedContexts.first(where: { !$0.meaning.isEmpty })?.meaning ?? ""
    }
}

/// A real sentence in which a word was found.
@Model
final class WordContext {
    /// Exact form that was tapped ("running").
    var form: String
    /// Original sentence, exactly as transcribed.
    var sentence: String
    /// Brazilian-Portuguese translation of the whole sentence.
    var sentenceTranslation: String = ""
    /// Meaning of the word in this specific sentence (pt-BR).
    var meaning: String = ""
    var createdAt: Date
    var word: VocabWord?

    init(form: String, sentence: String, date: Date = .now) {
        self.form = form
        self.sentence = sentence
        self.createdAt = date
    }

    var needsEnrichment: Bool { sentenceTranslation.isEmpty || meaning.isEmpty }
}
