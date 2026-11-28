import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Explains what a word means *in that sentence*, in Brazilian Portuguese.
/// Uses Apple Intelligence's free on-device model when available (iOS 26,
/// compatible iPhones); otherwise falls back to on-device translation of the
/// dictionary form plus its part of speech.
@MainActor
enum MeaningService {
    static func meaning(word: String, offset: Int?, sentence: String, sentenceTranslation: String?,
                        translator: TranslationService) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if let answer = await AppleIntelligenceMeaning.meaning(word: word, sentence: sentence,
                                                                    translation: sentenceTranslation) {
                return answer
            }
        }
        #endif
        let lemma = Lemmatizer.lemma(of: word, at: offset, in: sentence)
        guard let translated = await translator.translate(lemma) else { return nil }
        let partOfSpeech = Lemmatizer.partOfSpeech(of: word, at: offset, in: sentence)
        let base = translated.trimmingCharacters(in: CharacterSet(charactersIn: " .!?")).lowercased()
        if let partOfSpeech { return "\(base) (\(partOfSpeech))" }
        return base
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, *)
enum AppleIntelligenceMeaning {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func meaning(word: String, sentence: String, translation: String?) async -> String? {
        guard isAvailable else { return nil }
        let instructions = """
        Você é um dicionário inglês→português do Brasil para estudantes. \
        Responda somente com o significado da palavra no contexto dado, em português do Brasil, \
        em no máximo 12 palavras, sem aspas, sem repetir a palavra em inglês e sem explicações extras.
        """
        var prompt = "Palavra: \(word)\nFrase: \(sentence)\n"
        if let translation { prompt += "Tradução da frase: \(translation)\n" }
        prompt += "Significado da palavra nesta frase:"
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            let cleaned = response.content
                .components(separatedBy: .newlines).first?
                .trimmingCharacters(in: CharacterSet(charactersIn: " \"“”'.:"))
            guard let cleaned, !cleaned.isEmpty, cleaned.count < 160 else { return nil }
            return cleaned
        } catch {
            return nil
        }
    }
}
#endif
