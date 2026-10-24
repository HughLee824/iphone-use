import XCTest
@testable import IPhoneUseCore

final class RunnerTextTransactionTests: XCTestCase {
    private enum Failure: Error { case changed, apple }

    private final class Harness {
        var time: TimeInterval = 0
        var pauses: [TimeInterval] = []
        var advanceOnPause = true
        lazy var transaction = RunnerTextTransaction(now: { self.time }, pause: {
            self.pauses.append($0)
            if self.advanceOnPause { self.time += $0 }
        })
        var value = "old"
        var events: [String] = []
        var validationCount = 0
        var focus: (() -> Void)?
        var onEvent: ((String) throws -> Void)?
        var onValidate: ((Bool) throws -> Void)?

        func run(needsFocus: Bool = true, append: Bool = false, insert: Bool = false) throws {
            _ = try transaction.run(
                initial: value, needsFocus: needsFocus,
                focus: { self.events.append("focus"); self.focus?() },
                validate: { allowValueChange in
                    self.validationCount += 1
                    try self.onValidate?(allowValueChange)
                    return self.value
                }, plan: { current in
                    .init(replacing: !insert, deletion: current.isEmpty ? "" : "delete",
                          insertion: append ? current + "!" : "new")
                }, position: {
                    self.events.append("position"); try self.onEvent?("position")
                }, sendText: { text in
                    self.events.append(text)
                    self.value = text == "delete" ? "" : text
                    try self.onEvent?(text)
                }, isEmpty: { $0.isEmpty }, resultMatches: { $0 == $1 })
        }
    }

    func testFocusedFieldSkipsTapAndReplacementIsInsertedExactlyOnce() throws {
        let h = Harness()
        try h.run(needsFocus: false)
        XCTAssertEqual(h.events, ["position", "delete", "new"])
        XCTAssertEqual(h.value, "new")
        XCTAssertEqual(h.transaction.stage, "completed")
        XCTAssertFalse(h.transaction.focusAttempted)
        XCTAssertTrue(h.transaction.insertionAcknowledged)
    }

    func testIdentityReplacementDuringFocusStopsBeforeAnyKeyboardEvent() {
        let h = Harness()
        h.onValidate = { _ in throw Failure.changed }
        XCTAssertThrowsError(try h.run())
        XCTAssertEqual(h.events, ["focus"])
        XCTAssertTrue(h.transaction.focusCompleted)
        XCTAssertEqual(h.transaction.keyboardEventsAttempted, 0)
        XCTAssertFalse(h.transaction.insertionAttempted)
    }

    func testFreshValidationRunsAfterFocusAndBeforeClearing() {
        let h = Harness()
        h.onValidate = { _ in if h.validationCount == 2 { throw Failure.changed } }
        XCTAssertThrowsError(try h.run())
        XCTAssertEqual(h.events, ["focus", "position"])
        XCTAssertEqual(h.value, "old")
    }

    func testReplacementDuringClearDoesNotInsertOrRepeatDeletion() {
        let h = Harness()
        h.onValidate = { _ in if h.validationCount == 3 { throw Failure.changed } }
        XCTAssertThrowsError(try h.run())
        XCTAssertEqual(h.events, ["focus", "position", "delete"])
        XCTAssertFalse(h.transaction.insertionAttempted)
        XCTAssertEqual(h.transaction.stage, "verifying_clear")
    }

    func testExternalEditAfterClearIsNotOverwritten() {
        let h = Harness()
        h.onValidate = { _ in if h.validationCount == 4 { h.value = "external edit" } }
        XCTAssertThrowsError(try h.run()) {
            XCTAssertEqual($0 as? RunnerTextTransaction.Failure, .clearUnconfirmed)
        }
        XCTAssertTrue(h.transaction.clearConfirmed)
        XCTAssertEqual(h.events, ["focus", "position", "delete"])
        XCTAssertEqual(h.value, "external edit")
    }

    func testAppleFailureAfterInsertionIsReportedWithoutReplay() {
        let h = Harness()
        h.onEvent = { if $0 == "new" { throw Failure.apple } }
        XCTAssertThrowsError(try h.run())
        XCTAssertEqual(h.events, ["focus", "position", "delete", "new"])
        XCTAssertEqual(h.value, "new")
        XCTAssertTrue(h.transaction.insertionAttempted)
        XCTAssertFalse(h.transaction.insertionAcknowledged)
        XCTAssertEqual(h.transaction.stage, "inserting")
        XCTAssertEqual(h.transaction.facts["automaticReplayAllowed"] as? Bool, false)
    }

    func testUnconfirmedInsertionDoesNotRetry() {
        let h = Harness()
        h.onEvent = { if $0 == "new" { h.value = "partial" } }
        XCTAssertThrowsError(try h.run()) {
            XCTAssertEqual($0 as? RunnerTextTransaction.Failure, .resultUnconfirmed)
        }
        XCTAssertEqual(h.events.filter { $0 == "new" }.count, 1)
        XCTAssertTrue(h.transaction.insertionAcknowledged)
        XCTAssertEqual(h.transaction.stage, "verifying_result")
    }

    func testPathChangeAfterAcknowledgedInsertionDoesNotReplay() {
        let h = Harness()
        h.onValidate = { _ in if h.validationCount == 5 { throw Failure.changed } }
        XCTAssertThrowsError(try h.run())
        XCTAssertEqual(h.value, "new")
        XCTAssertEqual(h.events.filter { $0 == "new" }.count, 1)
        XCTAssertTrue(h.transaction.insertionAcknowledged)
        XCTAssertEqual(h.transaction.stage, "verifying_result")
        XCTAssertEqual(h.transaction.facts["automaticReplayAllowed"] as? Bool, false)
    }

    func testAppendPlanUsesValidatedPostFocusValueAndInsertsOnce() throws {
        let h = Harness()
        h.focus = { h.value = "validated" }
        try h.run(append: true)
        XCTAssertEqual(h.value, "validated!")
        XCTAssertEqual(h.events, ["focus", "position", "delete", "validated!"])
    }

    func testPostInsertionGeometryConvergesUsingFreshReadsWithoutReplay() throws {
        let h = Harness()
        h.onValidate = { _ in
            if [5, 6].contains(h.validationCount) { throw RunnerAXTree.Failure.geometryChanged }
        }
        try h.run()
        XCTAssertEqual(h.validationCount, 7)
        XCTAssertEqual(h.transaction.geometryRetries, 2)
        XCTAssertEqual(h.events, ["focus", "position", "delete", "new"])
        XCTAssertEqual(h.value, "new")
        XCTAssertFalse(h.transaction.convergenceTimedOut)
    }

    func testInsertConvergesWithoutFocusDeletionOrDuplicateInput() throws {
        let h = Harness()
        h.value = ""
        h.onValidate = { _ in
            if [3, 4].contains(h.validationCount) { throw RunnerAXTree.Failure.geometryChanged }
        }
        try h.run(needsFocus: false, insert: true)
        XCTAssertEqual(h.events, ["new"])
        XCTAssertEqual(h.transaction.keyboardEventsAttempted, 1)
        XCTAssertEqual(h.transaction.geometryRetries, 2)
        XCTAssertEqual(h.value, "new")
    }

    func testClearGeometryConvergesBeforeSingleInsertion() throws {
        let h = Harness()
        h.onValidate = { _ in
            if [3, 4].contains(h.validationCount) { throw RunnerAXTree.Failure.geometryChanged }
        }
        try h.run()
        XCTAssertTrue(h.transaction.clearConfirmed)
        XCTAssertEqual(h.events, ["focus", "position", "delete", "new"])
    }

    func testFocusAndPositionGeometryConvergeWithoutRepeatingEitherEvent() throws {
        let h = Harness()
        h.onValidate = { _ in
            if [1, 3].contains(h.validationCount) { throw RunnerAXTree.Failure.geometryChanged }
        }
        try h.run()
        XCTAssertEqual(h.events, ["focus", "position", "delete", "new"])
        XCTAssertEqual(h.transaction.geometryRetries, 2)
        XCTAssertEqual(h.transaction.keyboardEventsAttempted, 3)
    }

    func testGeometryBeforeInputIsNotRetried() {
        let h = Harness()
        h.onValidate = { _ in throw RunnerAXTree.Failure.geometryChanged }
        XCTAssertThrowsError(try h.run(needsFocus: false))
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertTrue(h.pauses.isEmpty)
    }

    func testIdentityChangeWhileConvergingStopsImmediately() {
        let h = Harness()
        h.onValidate = { _ in
            if h.validationCount == 5 { throw RunnerAXTree.Failure.geometryChanged }
            if h.validationCount == 6 { throw RunnerAXTree.Failure.targetChanged }
        }
        XCTAssertThrowsError(try h.run()) {
            XCTAssertEqual($0 as? RunnerAXTree.Failure, .targetChanged)
        }
        XCTAssertEqual(h.validationCount, 6)
        XCTAssertEqual(h.events, ["focus", "position", "delete", "new"])
    }

    func testGeometryRetriesStopAtReadLimitEvenWhenClockDoesNotAdvance() {
        let h = Harness()
        h.advanceOnPause = false
        h.onValidate = { _ in
            if h.validationCount >= 5 { throw RunnerAXTree.Failure.geometryChanged }
        }
        XCTAssertThrowsError(try h.run()) {
            XCTAssertEqual($0 as? RunnerTextTransaction.Failure, .geometryUnsettled)
        }
        XCTAssertEqual(h.validationCount, 10)
        XCTAssertEqual(h.transaction.geometryRetries, 5)
        XCTAssertTrue(h.transaction.convergenceTimedOut)
        XCTAssertTrue(h.transaction.insertionAcknowledged)
        XCTAssertEqual(h.events.filter { $0 == "new" }.count, 1)
    }

    func testSlowReadConsumesDeadlineAndDoesNotScheduleAnotherRead() {
        let h = Harness()
        h.onValidate = { _ in
            if h.validationCount == 5 {
                h.time += 5.1
                throw RunnerAXTree.Failure.geometryChanged
            }
        }
        XCTAssertThrowsError(try h.run()) {
            XCTAssertEqual($0 as? RunnerTextTransaction.Failure, .geometryUnsettled)
        }
        XCTAssertEqual(h.validationCount, 5)
        XCTAssertTrue(h.pauses.isEmpty)
        XCTAssertTrue(h.transaction.insertionAcknowledged)
    }

    func testSuccessfulReadAfterDeadlineIsNotReportedAsConverged() {
        let h = Harness()
        h.onValidate = { _ in if h.validationCount == 5 { h.time += 5.1 } }
        XCTAssertThrowsError(try h.run()) {
            XCTAssertEqual($0 as? RunnerTextTransaction.Failure, .geometryUnsettled)
        }
        XCTAssertTrue(h.transaction.convergenceTimedOut)
    }

    func testFinalValueIsCheckedAfterGeometryRecovers() {
        let h = Harness()
        h.onValidate = { _ in
            if h.validationCount == 5 { throw RunnerAXTree.Failure.geometryChanged }
            if h.validationCount == 6 { h.value = "external edit" }
        }
        XCTAssertThrowsError(try h.run()) {
            XCTAssertEqual($0 as? RunnerTextTransaction.Failure, .resultUnconfirmed)
        }
        XCTAssertEqual(h.events.filter { $0 == "new" }.count, 1)
    }
}
