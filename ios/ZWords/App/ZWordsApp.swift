import SwiftData
import SwiftUI

@main
struct ZWordsApp: App {
    private let container: ModelContainer
    @StateObject private var translator: TranslationService
    @StateObject private var engine: CaptionEngine
    @StateObject private var vocabulary: VocabularyStore

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: VocabWord.self, WordContext.self)
        } catch {
            // Last resort: keep the app usable even if the store cannot be opened.
            container = try! ModelContainer(for: VocabWord.self, WordContext.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        self.container = container
        let translator = TranslationService()
        _translator = StateObject(wrappedValue: translator)
        _engine = StateObject(wrappedValue: CaptionEngine(translator: translator))
        _vocabulary = StateObject(wrappedValue: VocabularyStore(
            context: container.mainContext,
            translate: { await translator.translate($0) },
            explain: { word, offset, sentence, translation in
                await MeaningService.meaning(word: word, offset: offset, sentence: sentence,
                                             sentenceTranslation: translation, translator: translator)
            }))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(translator)
                .environmentObject(engine)
                .environmentObject(vocabulary)
                .modelContainer(container)
        }
    }
}
