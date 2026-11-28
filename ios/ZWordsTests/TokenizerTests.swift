import XCTest
@testable import ZWords

final class TokenizerTests: XCTestCase {
    func testChunksKeepPunctuationButExposeCleanWords() {
        let chunks = Tokenizer.chunks(in: "Well, I’m not sure — it's 5 o'clock!")
        XCTAssertEqual(chunks.map(\.display), ["Well,", "I’m", "not", "sure", "—", "it's", "5", "o'clock!"])
        XCTAssertEqual(chunks.map(\.word), ["Well", "I'm", "not", "sure", nil, "it's", nil, "o'clock"])
    }

    func testWordOffsetsPointIntoSentence() {
        let sentence = "\"Hello,\" she said."
        let chunk = Tokenizer.chunks(in: sentence)[0]
        XCTAssertEqual(chunk.word, "Hello")
        XCTAssertEqual(chunk.wordOffset, 1)
    }

    func testSentencesAreSplit() {
        let sentences = Tokenizer.sentences(in: "I went home. It was late! Did you call?")
        XCTAssertEqual(sentences, ["I went home.", "It was late!", "Did you call?"])
    }

    func testEmptySentence() {
        XCTAssertEqual(Tokenizer.sentences(in: "   "), [])
    }

    func testPiPTailKeepsMostRecentWords() {
        let text = "one two three four five six seven eight nine ten"
        let tail = CaptionPiP.tail(text, maxCharacters: 15)
        XCTAssertTrue(tail.hasPrefix("…"))
        XCTAssertTrue(tail.hasSuffix("nine ten"))
    }
}
