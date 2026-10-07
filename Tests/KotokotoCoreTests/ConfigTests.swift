import XCTest
@testable import KotokotoCore

final class ConfigTests: XCTestCase {
    func testEmptyObjectGivesDefaults() throws {
        XCTAssertEqual(try Config.parse(Data("{}".utf8)), Config())
    }

    func testOverride() throws {
        let c = try Config.parse(Data(#"{"capsLock":"none","rightCommand":"korean","maxTapDuration":0.3}"#.utf8))
        XCTAssertEqual(c.capsLock, .none)
        XCTAssertNil(c.capsLock.language)
        XCTAssertEqual(c.rightCommand.language, .korean)
        XCTAssertEqual(c.leftCommand, .english)
        XCTAssertEqual(c.maxTapDuration, 0.3)
    }

    func testMethodsDefaultToInputSourceAndCanBeKey() throws {
        XCTAssertEqual(Config().englishMethod, .inputSource)
        XCTAssertEqual(Config().japaneseMethod, .inputSource)
        let c = try Config.parse(Data(#"{"japaneseMethod":"key"}"#.utf8))
        XCTAssertEqual(c.japaneseMethod, .key)
        XCTAssertEqual(c.englishMethod, .inputSource)
        XCTAssertThrowsError(try Config.parse(Data(#"{"englishMethod":"magic"}"#.utf8)))
    }

    func testTraceDefaultsToFalse() throws {
        XCTAssertFalse(Config().trace)
        XCTAssertTrue(try Config.parse(Data(#"{"trace":true}"#.utf8)).trace)
    }

    func testUnknownTargetThrows() {
        XCTAssertThrowsError(try Config.parse(Data(#"{"capsLock":"klingon"}"#.utf8)))
    }

    func testNonPositiveDurationThrows() {
        XCTAssertThrowsError(try Config.parse(Data(#"{"maxTapDuration":0}"#.utf8)))
    }

    func testTemplateRoundTrips() throws {
        XCTAssertEqual(try Config.parse(try Config().templateData()), Config())
    }
}
