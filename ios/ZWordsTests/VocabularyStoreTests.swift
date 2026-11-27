import SwiftData
import XCTest
@testable import ZWords

@MainActor
final class VocabularyStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var store: VocabularyStore!

    override func setUp() async throws {
        container = try ModelContainer(for: VocabWord.self, WordContext.self,
                                       configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        store = VocabularyStore(context: container.mainContext,
                                translate: { "PT: \($0)" },
                                explain: { word, _, _, _ in "significado de \(word)" })
    }

    private func allWords() throws -> [VocabWord] {
        try container.mainContext.fetch(FetchDescriptor<VocabWord>())
    }

    func testSavingCreatesEntryWithContext() throws {
        store.save(word: "apple", offset: 4, sentence: "She ate an apple.", enrich: false)
        let words = try allWords()
        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(words[0].contexts.count, 1)
        XCTAssertEqual(words[0].contexts[0].form, "apple")
        XCTAssertEqual(words[0].contexts[0].sentence, "She ate an apple.")
        XCTAssertTrue(store.isSaved("Apple"))
    }

    func testSameSentenceIsNotDuplicated() throws {
        store.save(word: "apple", offset: nil, sentence: "She ate an apple.", enrich: false)
        store.save(word: "apple", offset: nil, sentence: "She ate an apple.", enrich: false)
        let words = try allWords()
        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(words[0].contexts.count, 1)
    }

    func testNewSentenceIsAddedToExistingWord() throws {
        store.save(word: "apple", offset: nil, sentence: "She ate an apple.", enrich: false)
        store.save(word: "Apple", offset: nil, sentence: "An apple a day keeps the doctor away.", enrich: false)
        let words = try allWords()
        XCTAssertEqual(words.count, 1)
        XCTAssertEqual(words[0].contexts.count, 2)
    }

    func testEnrichmentFillsTranslationAndMeaning() async throws {
        store.save(word: "apple", offset: nil, sentence: "She ate an apple.", enrich: false)
        await store.enrichPending()
        let item = try XCTUnwrap(try allWords().first?.contexts.first)
        XCTAssertEqual(item.sentenceTranslation, "PT: She ate an apple.")
        XCTAssertEqual(item.meaning, "significado de apple")
        XCTAssertFalse(item.needsEnrichment)
    }

    func testDeletingLastContextRemovesWord() throws {
        store.save(word: "apple", offset: nil, sentence: "She ate an apple.", enrich: false)
        let item = try XCTUnwrap(try allWords().first?.contexts.first)
        store.delete(item)
        XCTAssertEqual(try allWords().count, 0)
        XCTAssertFalse(store.isSaved("apple"))
    }

    func testReviewSchedulesNextDate() throws {
        store.save(word: "apple", offset: nil, sentence: "She ate an apple.", enrich: false)
        let word = try XCTUnwrap(try allWords().first)
        let now = Date()
        store.review(word, remembered: true, now: now)
        XCTAssertEqual(word.reviewBox, 1)
        XCTAssertEqual(word.nextReview.timeIntervalSince(now), 86_400, accuracy: 1)
        store.review(word, remembered: false, now: now)
        XCTAssertEqual(word.reviewBox, 0)
    }
}
