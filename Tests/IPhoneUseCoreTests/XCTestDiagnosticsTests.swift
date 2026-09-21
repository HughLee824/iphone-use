import XCTest
@testable import IPhoneUseCore

final class XCTestDiagnosticsTests: XCTestCase {
    private var originalArguments: [String: Any] = [:]

    override func setUpWithError() throws {
        // The argument domain is process-wide even when persistent suite names differ.
        originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = originalArguments
        arguments.removeValue(forKey: "XCTDisableSpindump")
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "iphone-use-diagnostics-test-\(UUID().uuidString)")!
    }

    @MainActor
    func testAbsentKeyIsTemporarilyEnabledWithoutPersistentWrites() throws {
        let defaults = isolatedDefaults()
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        XCTAssertNil(original["XCTDisableSpindump"])
        let value = XCTestDiagnostics.withoutAutomaticSpindump(defaults: defaults) {
            XCTAssertTrue(defaults.bool(forKey: "XCTDisableSpindump"))
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(defaults.volatileDomain(forName: UserDefaults.argumentDomain) as NSDictionary, original as NSDictionary)
        XCTAssertFalse(defaults.bool(forKey: "XCTDisableSpindump"))
    }

    @MainActor
    func testExistingValuesAreRestoredExactly() {
        for value in [false, true, "NO"] as [Any] {
            let defaults = isolatedDefaults()
            let original: [String: Any] = ["XCTDisableSpindump": value, "unrelated": "keep"]
            defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
            XCTestDiagnostics.withoutAutomaticSpindump(defaults: defaults) {
                XCTAssertTrue(defaults.bool(forKey: "XCTDisableSpindump"))
            }
            XCTAssertEqual(defaults.volatileDomain(forName: UserDefaults.argumentDomain) as NSDictionary, original as NSDictionary)
        }
    }

    @MainActor
    func testThrowingAndNestedScopesRestoreWithoutSwallowingErrors() {
        enum Failure: Error { case expected }
        let defaults = isolatedDefaults()
        XCTAssertThrowsError(try XCTestDiagnostics.withoutAutomaticSpindump(defaults: defaults) {
            XCTestDiagnostics.withoutAutomaticSpindump(defaults: defaults) {
                XCTAssertTrue(defaults.bool(forKey: "XCTDisableSpindump"))
            }
            XCTAssertTrue(defaults.bool(forKey: "XCTDisableSpindump"))
            throw Failure.expected
        }) { XCTAssertTrue($0 is Failure) }
        XCTAssertNil(defaults.volatileDomain(forName: UserDefaults.argumentDomain)["XCTDisableSpindump"])
        XCTAssertFalse(defaults.bool(forKey: "XCTDisableSpindump"))
    }

    @MainActor
    func testUnrelatedChangesInsideScopeSurviveRestoration() {
        let defaults = isolatedDefaults()
        XCTestDiagnostics.withoutAutomaticSpindump(defaults: defaults) {
            var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["unrelated"] = "new value"
            defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        }
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "new value")
        XCTAssertNil(defaults.volatileDomain(forName: UserDefaults.argumentDomain)["XCTDisableSpindump"])
    }
}
