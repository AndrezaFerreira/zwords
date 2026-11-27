import XCTest
@testable import ZWords

final class LemmatizerTests: XCTestCase {
    func testRangeUsesOffsetAndFallsBackToSearch() {
        let sentence = "The dog chased the other dog."
        let second = Lemmatizer.range(of: "dog", at: 25, in: sentence)
        XCTAssertEqual(second.map { String(sentence[$0]) }, "dog")
        XCTAssertEqual(second.map { sentence.distance(from: sentence.startIndex, to: $0.lowerBound) }, 25)
        let fallback = Lemmatizer.range(of: "Chased", at: 999, in: sentence)
        XCTAssertEqual(fallback.map { String(sentence[$0]) }, "chased")
    }

    func testCurlyApostropheRange() {
        let sentence = "I don’t know."
        XCTAssertNotNil(Lemmatizer.range(of: "don't", at: nil, in: sentence))
    }

    func testContractionsAreNotLemmatized() {
        XCTAssertEqual(Lemmatizer.lemma(of: "I'm", at: 0, in: "I'm tired."), "i'm")
    }

    func testLemmaIsLowercaseLetters() {
        let lemma = Lemmatizer.lemma(of: "Running", at: 0, in: "Running every day is hard.")
        XCTAssertEqual(lemma, lemma.lowercased())
        XCTAssertTrue(["run", "running"].contains(lemma))
    }
}
