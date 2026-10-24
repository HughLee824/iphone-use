import Foundation
import XCTest

final class FixtureResourcesTests: XCTestCase {
    func testBundleContainsOnlySelectedRegressionInputs() throws {
        let directory = try XCTUnwrap(Bundle.module.resourceURL)
        let expected = Set(
            ["app.json", "system-alert.json", "encoded-source.png", "caret-source.png"]
                + (0..<6).map { "encoded-\($0).png" }
                + (1...6).map { "caret-\($0).png" })
        let actual = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(
            Set(actual), expected, "Do not bundle documentation, local metadata or whole fixture directories.")
    }
}
