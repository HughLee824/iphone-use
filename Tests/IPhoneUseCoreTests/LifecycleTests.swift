import XCTest
@testable import IPhoneUseCore

final class LifecycleTests: XCTestCase {
    func testDefaultAndAdjustableDurations() throws {
        XCTAssertEqual(try IdleTimeout("30m").seconds, 1800)
        XCTAssertEqual(try IdleTimeout("60m").seconds, 3600)
        XCTAssertEqual(try IdleTimeout("0.5s").seconds, 0.5)
        for invalid in ["0s", "-1s", "NaNm", "infh", "30", "1d"] {
            XCTAssertThrowsError(try IdleTimeout(invalid))
        }
    }

    func testInFlightAndQueuedCommandsRenewFromCompletion() {
        var state = SessionLifecycle(timeout: 30)
        state.ready(at: 100)
        XCTAssertTrue(state.accept(at: 129))
        XCTAssertTrue(state.accept(at: 140))
        XCTAssertFalse(state.isExpired(at: 200))
        state.finish(effective: true, at: 200)
        XCTAssertFalse(state.isExpired(at: 240)) // Another admitted command is still queued.
        state.finish(effective: true, at: 250)
        XCTAssertFalse(state.isExpired(at: 279))
        XCTAssertTrue(state.isExpired(at: 280))
    }

    func testHealthChecksDoNotRenewAndExpiredRequestsCannotRevive() {
        var state = SessionLifecycle(timeout: 30)
        state.ready(at: 100)
        XCTAssertTrue(state.accept(at: 129))
        state.finish(effective: false, at: 131)
        XCTAssertTrue(state.isExpired(at: 131))
        XCTAssertFalse(state.accept(at: 131))
        XCTAssertEqual(state.lastActivity, 100)
    }

    func testClosingRejectsNewRequestsAndCannotBeReopenedByCompletion() {
        var state = SessionLifecycle(timeout: 30)
        state.ready(at: 100)
        XCTAssertTrue(state.accept(at: 110))
        state.close()
        XCTAssertFalse(state.accept(at: 111))
        state.finish(effective: true, at: 112)
        XCTAssertFalse(state.accept(at: 113))
    }
}
