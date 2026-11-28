import XCTest
@testable import ZWords

@MainActor
final class CaptionEngineTests: XCTestCase {
    func testSegmentsBecomeSentenceLinesAndUpdateInPlace() {
        let engine = CaptionEngine(translator: TranslationService())
        engine.apply(key: "m1-1", text: "Hello there", isFinal: false)
        XCTAssertEqual(engine.lines.map(\.text), ["Hello there"])
        XCTAssertFalse(engine.lines[0].isFinal)

        engine.apply(key: "m1-1", text: "Hello there. How are you?", isFinal: true)
        XCTAssertEqual(engine.lines.map(\.text), ["Hello there.", "How are you?"])
        XCTAssertTrue(engine.lines.allSatisfy(\.isFinal))

        engine.apply(key: "m1-2", text: "Fine", isFinal: false)
        XCTAssertEqual(engine.lines.count, 3)

        // An empty final result removes the segment.
        engine.apply(key: "m1-2", text: "", isFinal: true)
        XCTAssertEqual(engine.lines.count, 2)
    }
}
