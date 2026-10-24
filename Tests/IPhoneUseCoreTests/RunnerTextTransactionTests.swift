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
                events: .init(focus: { self.events.append("focus"); self.focus?() }, position: {
                    self.events.append("position"); try self.onEvent?("position")
                }, sendText: { text in
                    self.events.append(text)
                    self.value = text == "delete" ? "" : text
                    try self.onEvent?(text)
                }), validation: .init(read: { allowValueChange in
                    self.validationCount += 1
                    try self.onValidate?(allowValueChange)
                    return self.value
                }, isEmpty: { $0.isEmpty }, resultMatches: { $0 == $1 }), plan: { current in
                    .init(replacing: !insert, deletion: current.isEmpty ? "" : "delete",
                          insertion: append ? current + "!" : "new")
                })
        }
    }

    func testFocusedFieldSkipsTapAndReplacementIsInsertedExactlyOnce() throws {
        let harness = Harness()
        try harness.run(needsFocus: false)
        XCTAssertEqual(harness.events, ["position", "delete", "new"])
        XCTAssertEqual(harness.value, "new")
        XCTAssertEqual(harness.transaction.stage, "completed")
        XCTAssertFalse(harness.transaction.focusAttempted)
        XCTAssertTrue(harness.transaction.insertionAcknowledged)
    }

    func testIdentityReplacementDuringFocusStopsBeforeAnyKeyboardEvent() {
        let harness = Harness()
        harness.onValidate = { _ in throw Failure.changed }
        XCTAssertThrowsError(try harness.run())
        XCTAssertEqual(harness.events, ["focus"])
        XCTAssertTrue(harness.transaction.focusCompleted)
        XCTAssertEqual(harness.transaction.keyboardEventsAttempted, 0)
        XCTAssertFalse(harness.transaction.insertionAttempted)
    }

    func testFreshValidationRunsAfterFocusAndBeforeClearing() {
        let harness = Harness()
        harness.onValidate = { _ in if harness.validationCount == 2 { throw Failure.changed } }
        XCTAssertThrowsError(try harness.run())
        XCTAssertEqual(harness.events, ["focus", "position"])
        XCTAssertEqual(harness.value, "old")
    }

    func testReplacementDuringClearDoesNotInsertOrRepeatDeletion() {
        let harness = Harness()
        harness.onValidate = { _ in if harness.validationCount == 3 { throw Failure.changed } }
        XCTAssertThrowsError(try harness.run())
        XCTAssertEqual(harness.events, ["focus", "position", "delete"])
        XCTAssertFalse(harness.transaction.insertionAttempted)
        XCTAssertEqual(harness.transaction.stage, "verifying_clear")
    }

    func testExternalEditAfterClearIsNotOverwritten() {
        let harness = Harness()
        harness.onValidate = { _ in if harness.validationCount == 4 { harness.value = "external edit" } }
        XCTAssertThrowsError(try harness.run()) {
            XCTAssertEqual($0 as? RunnerTextTransaction.Failure, .clearUnconfirmed)
        }
        XCTAssertTrue(harness.transaction.clearConfirmed)
        XCTAssertEqual(harness.events, ["focus", "position", "delete"])
        XCTAssertEqual(harness.value, "external edit")
    }

    func testAppleFailureAfterInsertionIsReportedWithoutReplay() {
        let harness = Harness()
        harness.onEvent = { if $0 == "new" { throw Failure.apple } }
        XCTAssertThrowsError(try harness.run())
        XCTAssertEqual(harness.events, ["focus", "position", "delete", "new"])
        XCTAssertEqual(harness.value, "new")
        XCTAssertTrue(harness.transaction.insertionAttempted)
        XCTAssertFalse(harness.transaction.insertionAcknowledged)
        XCTAssertEqual(harness.transaction.stage, "inserting")
        XCTAssertEqual(harness.transaction.facts["automaticReplayAllowed"] as? Bool, false)
    }

    func testUnconfirmedInsertionDoesNotRetry() {
        let harness = Harness()
        harness.onEvent = { if $0 == "new" { harness.value = "partial" } }
        XCTAssertThrowsError(try harness.run()) {
            XCTAssertEqual($0 as? RunnerTextTransaction.Failure, .resultUnconfirmed)
        }
        XCTAssertEqual(harness.events.filter { $0 == "new" }.count, 1)
        XCTAssertTrue(harness.transaction.insertionAcknowledged)
        XCTAssertEqual(harness.transaction.stage, "verifying_result")
    }

    func testPathChangeAfterAcknowledgedInsertionDoesNotReplay() {
        let harness = Harness()
        harness.onValidate = { _ in if harness.validationCount == 5 { throw Failure.changed } }
        XCTAssertThrowsError(try harness.run())
        XCTAssertEqual(harness.value, "new")
        XCTAssertEqual(harness.events.filter { $0 == "new" }.count, 1)
        XCTAssertTrue(harness.transaction.insertionAcknowledged)
        XCTAssertEqual(harness.transaction.stage, "verifying_result")
        XCTAssertEqual(harness.transaction.facts["automaticReplayAllowed"] as? Bool, false)
    }

    func testAppendPlanUsesValidatedPostFocusValueAndInsertsOnce() throws {
        let harness = Harness()
        harness.focus = { harness.value = "validated" }
        try harness.run(append: true)
        XCTAssertEqual(harness.value, "validated!")
        XCTAssertEqual(harness.events, ["focus", "position", "delete", "validated!"])
    }

    func testPostInsertionGeometryConvergesUsingFreshReadsWithoutReplay() throws {
        let harness = Harness()
        harness.onValidate = { _ in
            if [5, 6].contains(harness.validationCount) { throw RunnerAXTree.Failure.geometryChanged }
        }
        try harness.run()
        XCTAssertEqual(harness.validationCount, 7)
        XCTAssertEqual(harness.transaction.geometryRetries, 2)
        XCTAssertEqual(harness.events, ["focus", "position", "delete", "new"])
        XCTAssertEqual(harness.value, "new")
        XCTAssertFalse(harness.transaction.convergenceTimedOut)
    }

    func testInsertConvergesWithoutFocusDeletionOrDuplicateInput() throws {
        let harness = Harness()
        harness.value = ""
        harness.onValidate = { _ in
            if [3, 4].contains(harness.validationCount) { throw RunnerAXTree.Failure.geometryChanged }
        }
        try harness.run(needsFocus: false, insert: true)
        XCTAssertEqual(harness.events, ["new"])
        XCTAssertEqual(harness.transaction.keyboardEventsAttempted, 1)
        XCTAssertEqual(harness.transaction.geometryRetries, 2)
        XCTAssertEqual(harness.value, "new")
    }

    func testClearGeometryConvergesBeforeSingleInsertion() throws {
        let harness = Harness()
        harness.onValidate = { _ in
            if [3, 4].contains(harness.validationCount) { throw RunnerAXTree.Failure.geometryChanged }
        }
        try harness.run()
        XCTAssertTrue(harness.transaction.clearConfirmed)
        XCTAssertEqual(harness.events, ["focus", "position", "delete", "new"])
    }

    func testFocusAndPositionGeometryConvergeWithoutRepeatingEitherEvent() throws {
        let harness = Harness()
        harness.onValidate = { _ in
            if [1, 3].contains(harness.validationCount) { throw RunnerAXTree.Failure.geometryChanged }
        }
        try harness.run()
        XCTAssertEqual(harness.events, ["focus", "position", "delete", "new"])
        XCTAssertEqual(harness.transaction.geometryRetries, 2)
        XCTAssertEqual(harness.transaction.keyboardEventsAttempted, 3)
    }

    func testGeometryBeforeInputIsNotRetried() {
        let harness = Harness()
        harness.onValidate = { _ in throw RunnerAXTree.Failure.geometryChanged }
        XCTAssertThrowsError(try harness.run(needsFocus: false))
        XCTAssertTrue(harness.events.isEmpty)
        XCTAssertTrue(harness.pauses.isEmpty)
    }

    func testIdentityChangeWhileConvergingStopsImmediately() {
        let harness = Harness()
        harness.onValidate = { _ in
            if harness.validationCount == 5 { throw RunnerAXTree.Failure.geometryChanged }
            if harness.validationCount == 6 { throw RunnerAXTree.Failure.targetChanged }
        }
        XCTAssertThrowsError(try harness.run()) {
            XCTAssertEqual($0 as? RunnerAXTree.Failure, .targetChanged)
        }
        XCTAssertEqual(harness.validationCount, 6)
        XCTAssertEqual(harness.events, ["focus", "position", "delete", "new"])
    }

    func testGeometryRetriesStopAtReadLimitEvenWhenClockDoesNotAdvance() {
        let harness = Harness()
        harness.advanceOnPause = false
        harness.onValidate = { _ in
            if harness.validationCount >= 5 { throw RunnerAXTree.Failure.geometryChanged }
        }
        XCTAssertThrowsError(try harness.run()) {
            XCTAssertEqual($0 as? RunnerTextTransaction.Failure, .geometryUnsettled)
        }
        XCTAssertEqual(harness.validationCount, 10)
        XCTAssertEqual(harness.transaction.geometryRetries, 5)
        XCTAssertTrue(harness.transaction.convergenceTimedOut)
        XCTAssertTrue(harness.transaction.insertionAcknowledged)
        XCTAssertEqual(harness.events.filter { $0 == "new" }.count, 1)
    }

    func testSlowReadConsumesDeadlineAndDoesNotScheduleAnotherRead() {
        let harness = Harness()
        harness.onValidate = { _ in
            if harness.validationCount == 5 {
                harness.time += 5.1
                throw RunnerAXTree.Failure.geometryChanged
            }
        }
        XCTAssertThrowsError(try harness.run()) {
            XCTAssertEqual($0 as? RunnerTextTransaction.Failure, .geometryUnsettled)
        }
        XCTAssertEqual(harness.validationCount, 5)
        XCTAssertTrue(harness.pauses.isEmpty)
        XCTAssertTrue(harness.transaction.insertionAcknowledged)
    }

    func testSuccessfulReadAfterDeadlineIsNotReportedAsConverged() {
        let harness = Harness()
        harness.onValidate = { _ in if harness.validationCount == 5 { harness.time += 5.1 } }
        XCTAssertThrowsError(try harness.run()) {
            XCTAssertEqual($0 as? RunnerTextTransaction.Failure, .geometryUnsettled)
        }
        XCTAssertTrue(harness.transaction.convergenceTimedOut)
    }

    func testFinalValueIsCheckedAfterGeometryRecovers() {
        let harness = Harness()
        harness.onValidate = { _ in
            if harness.validationCount == 5 { throw RunnerAXTree.Failure.geometryChanged }
            if harness.validationCount == 6 { harness.value = "external edit" }
        }
        XCTAssertThrowsError(try harness.run()) {
            XCTAssertEqual($0 as? RunnerTextTransaction.Failure, .resultUnconfirmed)
        }
        XCTAssertEqual(harness.events.filter { $0 == "new" }.count, 1)
    }
}
