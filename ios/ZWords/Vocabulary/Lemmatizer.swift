import Foundation
import NaturalLanguage

/// Uses Apple's on-device NaturalLanguage models to find the dictionary form
/// of a word in its sentence ("ran" → "run", "mice" → "mouse").
enum Lemmatizer {
    static func lemma(of word: String, at utf16Offset: Int?, in sentence: String) -> String {
        let lower = word.lowercased()
        // Contractions ("I'm", "don't") are better kept as they are.
        guard !word.contains("'"), !word.contains("’"),
              let range = range(of: word, at: utf16Offset, in: sentence) else { return lower }
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = sentence
        let (tag, _) = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma)
        guard let lemma = tag?.rawValue.lowercased(), !lemma.isEmpty,
              lemma.allSatisfy({ $0.isLetter || $0 == "-" }) else { return lower }
        return lemma
    }

    /// Part of speech in Portuguese ("verbo", "substantivo"…).
    static func partOfSpeech(of word: String, at utf16Offset: Int?, in sentence: String) -> String? {
        guard let range = range(of: word, at: utf16Offset, in: sentence) else { return nil }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = sentence
        let (tag, _) = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lexicalClass)
        switch tag {
        case .noun?: return "substantivo"
        case .verb?: return "verbo"
        case .adjective?: return "adjetivo"
        case .adverb?: return "advérbio"
        case .pronoun?: return "pronome"
        case .preposition?: return "preposição"
        case .conjunction?: return "conjunção"
        case .determiner?: return "determinante"
        case .interjection?: return "interjeição"
        case .particle?: return "partícula"
        default: return nil
        }
    }

    static func range(of word: String, at utf16Offset: Int?, in sentence: String) -> Range<String.Index>? {
        let utf16 = sentence.utf16
        if let offset = utf16Offset, offset >= 0, offset + word.utf16.count <= utf16.count {
            let start = String.Index(utf16Offset: offset, in: sentence)
            let end = String.Index(utf16Offset: offset + word.utf16.count, in: sentence)
            let candidate = Tokenizer.normalize(String(sentence[start..<end]))
            if candidate.caseInsensitiveCompare(word) == .orderedSame { return start..<end }
        }
        let normalized = Tokenizer.normalize(sentence)
        guard let found = normalized.range(of: word, options: [.caseInsensitive]) else { return nil }
        // `normalize` only swaps same-length characters, so offsets carry over.
        let lower = normalized.utf16.distance(from: normalized.startIndex, to: found.lowerBound)
        let length = normalized.utf16.distance(from: found.lowerBound, to: found.upperBound)
        return String.Index(utf16Offset: lower, in: sentence)..<String.Index(utf16Offset: lower + length, in: sentence)
    }
}
