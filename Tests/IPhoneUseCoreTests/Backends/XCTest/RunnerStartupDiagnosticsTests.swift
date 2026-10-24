import XCTest
@testable import IPhoneUseCore

final class RunnerStartupDiagnosticsTests: XCTestCase {
    func testExitAndTimeoutReportDifferentObservedFactsWithoutInventingAuthorization() {
        let exit = RunnerStartupDiagnostics.failure(processExited: true)
        let timeout = RunnerStartupDiagnostics.failure(processExited: false)
        XCTAssertEqual(exit.code, "runner_start_failed")
        XCTAssertTrue(exit.description.contains("exited before USB readiness"))
        XCTAssertFalse(exit.description.contains("90 seconds"))
        XCTAssertTrue(timeout.description.contains("within 90 seconds"))
        for failure in [exit, timeout] {
            XCTAssertTrue(failure.description.contains("does not establish an authorization problem"))
            XCTAssertFalse(failure.description.contains("xcodebuild"))
            XCTAssertTrue(failure.description.contains("If Enable UI Automation"))
        }
    }
}
