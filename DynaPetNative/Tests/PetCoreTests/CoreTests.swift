import XCTest
@testable import PetCore

final class CoreTests: XCTestCase {
    func testDragDoesNotFeedWindowMotionBackIntoDelta() {
        var drag = WindowDrag()
        drag.begin(cursor: .init(x: 100, y: 100), bounds: .init(x: 20, y: 30, width: 290, height: 320))
        XCTAssertEqual(drag.updated(cursor: .init(x: 140, y: 160))?.origin, .init(x: 60, y: 90))
        XCTAssertEqual(drag.updated(cursor: .init(x: 145, y: 165))?.origin, .init(x: 65, y: 95))
        XCTAssertTrue(drag.end(cursor: .init(x: 145, y: 165)))
        XCTAssertNil(drag.updated(cursor: .init(x: 200, y: 200)))
    }
    func testClickDoesNotBecomeDrag() {
        var drag = WindowDrag()
        drag.begin(cursor: .init(x: -100, y: 20), bounds: .init(x: -200, y: 30, width: 290, height: 320))
        XCTAssertFalse(drag.end(cursor: .init(x: -98, y: 21)))
    }
    func testOriginalMoodPriorityIsShared() {
        var snapshot = Snapshot()
        snapshot.front = "Code"; snapshot.battery = 10
        XCTAssertEqual(decide(snapshot, screenTimeout: 300, greeting: false).mood, .low)
        snapshot.charging = true; snapshot.cpu = 90
        XCTAssertEqual(decide(snapshot, screenTimeout: 300, greeting: false).mood, .dizzy)
        snapshot.cpu = 0
        XCTAssertEqual(decide(snapshot, screenTimeout: 300, greeting: false).mood, .focus)
    }
    func testRejectsInvalidNativeWindowGeometry() {
        XCTAssertFalse(WindowBounds(x: .nan, y: 0, width: 100, height: 100).isValid)
        XCTAssertFalse(WindowBounds(x: 0, y: 0, width: -1, height: 100).isValid)
        XCTAssertTrue(WindowBounds(x: -300, y: -100, width: 290, height: 320).isValid)
    }
}
