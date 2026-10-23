import XCTest
import Foundation
@testable import IPhoneUseCore

// Sanitized AX with a synthetic full-screen PNG, independent of local device artifacts.
func observationFixture(_ name: String = "app.json") throws -> CapturedObservation {
    let fixture = try XCTUnwrap(
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Observations"))
    var result = try jsonObject(Data(contentsOf: fixture))
    result["screenshotBase64"] = try screenPNG().base64EncodedString()
    result["axStatus"] = "available"
    result["snapshotFinishedAt"] = result["screenshotCapturedAt"]
    result["screenFrame"] = ["x": 0, "y": 0, "width": 390, "height": 844]
    result["screenContext"] = try jsonObject(JSONEncoder().encode(screenTestContext()))
    if result["scope"] as? String == "app" { result["foregroundBundleId"] = result["bundleId"] }
    return try XCTestCapture.decode(result)
}

final class ObservationTests: XCTestCase {
    func cache() throws -> (ObservationCache, URL) {
        let directory = URL(fileURLWithPath: "/private/tmp/as-observe-\(UUID().uuidString.prefix(8))")
        try SessionPaths.secureDirectory(directory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (ObservationCache(directory: directory), directory)
    }

    func queryNodes(_ result: [String: Any]) throws -> [[String: Any]] {
        try ((try XCTUnwrap(result["text"] as? String))).split(separator: "\n").filter { $0.hasPrefix("{") }
            .map {
                try jsonObject(Data($0.utf8))
            }
    }
}
