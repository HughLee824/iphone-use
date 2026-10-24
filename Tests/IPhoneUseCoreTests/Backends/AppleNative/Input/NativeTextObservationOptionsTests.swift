import XCTest
@testable import IPhoneUseCore

final class NativeTextObservationOptionsTests: XCTestCase {
    func testMalformedOptionsFailBeforePreparation() throws {
        for value in ["0,0,0,10", "0,0,-1,10", "nan,0,10,10", "1,2,3"] {
            XCTAssertThrowsError(try NativeTextObservationOptions(request: ["fieldRect": value]))
        }
        XCTAssertThrowsError(try NativeTextObservationOptions(request: ["ignoreRect": "0,0,10,10"]))
    }
}
