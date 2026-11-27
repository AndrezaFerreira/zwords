import Foundation
import NaturalLanguage

/// A whitespace-delimited piece of a caption. `word` is the tappable English
/// word inside it (punctuation stripped), if any.
struct Chunk: Identifiable, Hashable {
    let id: Int
    let display: String
    let word: String?
    /// UTF-16 offset of `word` inside the source sentence.
    let wordOffset: Int
}

enum Tokenizer {
    private static let pieceRegex = try! NSRegularExpression(pattern: "\\S+")
    private static let wordRegex = try! NSRegularExpression(pattern: "\\p{L}+(?:['’\\-]\\p{L}+)*")

    static func chunks(in text: String) -> [Chunk] {
        let ns = text as NSString
        var result: [Chunk] = []
        let pieces = pieceRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for (index, piece) in pieces.enumerated() {
            let display = ns.substring(with: piece.range)
            var word: String?
            var offset = piece.range.location
            if let match = wordRegex.firstMatch(in: text, range: piece.range) {
                word = normalize(ns.substring(with: match.range))
                offset = match.range.location
            }
            result.append(Chunk(id: index, display: display, word: word, wordOffset: offset))
        }
        return result
    }

    static func normalize(_ word: String) -> String {
        word.replacingOccurrences(of: "’", with: "'")
    }

    /// Splits a transcribed segment into sentences.
    static func sentences(in text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed
        var output: [String] = []
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            let sentence = trimmed[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { output.append(sentence) }
            return true
        }
        return output.isEmpty ? [trimmed] : output
    }
}
