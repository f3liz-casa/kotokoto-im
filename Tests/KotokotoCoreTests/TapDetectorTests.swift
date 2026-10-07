import XCTest
@testable import KotokotoCore

final class TapDetectorTests: XCTestCase {
    func testLeftTap() {
        var d = TapDetector()
        XCTAssertNil(d.commandChanged(.left, isDown: true, at: 0))
        XCTAssertEqual(d.commandChanged(.left, isDown: false, at: 0.1), .left)
    }

    func testRightTap() {
        var d = TapDetector()
        XCTAssertNil(d.commandChanged(.right, isDown: true, at: 0))
        XCTAssertEqual(d.commandChanged(.right, isDown: false, at: 0.1), .right)
    }

    func testShortcutDoesNotFire() {
        var d = TapDetector()
        _ = d.commandChanged(.left, isDown: true, at: 0)
        d.otherInput() // ⌘+C
        XCTAssertNil(d.commandChanged(.left, isDown: false, at: 0.1))
    }

    func testLongPressDoesNotFire() {
        var d = TapDetector()
        _ = d.commandChanged(.right, isDown: true, at: 0)
        XCTAssertNil(d.commandChanged(.right, isDown: false, at: 1.0))
    }

    func testBothCommandsDoNotFire() {
        var d = TapDetector()
        _ = d.commandChanged(.left, isDown: true, at: 0)
        _ = d.commandChanged(.right, isDown: true, at: 0.05)
        XCTAssertNil(d.commandChanged(.right, isDown: false, at: 0.1))
        XCTAssertNil(d.commandChanged(.left, isDown: false, at: 0.15))
    }

    func testFiresAgainAfterCancel() {
        var d = TapDetector()
        _ = d.commandChanged(.left, isDown: true, at: 0)
        d.otherInput()
        _ = d.commandChanged(.left, isDown: false, at: 0.1)
        _ = d.commandChanged(.left, isDown: true, at: 1)
        XCTAssertEqual(d.commandChanged(.left, isDown: false, at: 1.1), .left)
    }
}
