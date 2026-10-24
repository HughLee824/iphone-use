@testable import IPhoneUseRunnerSupport
import XCTest
@testable import IPhoneUseCore

final class NativePostActionStabilityTests: XCTestCase {
    func frame(_ color: UInt8 = 100, rotation: String = "rot0", patch: Bool = false) throws
        -> CapturedObservation {
        let png = try screenPNG(
            width: 40, height: 80,
            patches: [(CGRect(x: 0, y: 0, width: 40, height: 80), [color, color, color])]
                + (patch ? [(CGRect(x: 5, y: 5, width: 5, height: 5), [0, 0, 0])] : []))
        let rect = ScreenRect(CGRect(x: 0, y: 0, width: 40, height: 80))
        let context = ScreenContext(
            screen: rect, scope: rect, orientation: rotation == "rot0" ? 1 : 3, keyboardCount: 0)
        return CapturedObservation(
            nodes: [],
            metadata: [
                "captureSource": "coredevice_screenshot",
                "displayRotation": rotation, "displayID": 1, "nativeRotation": "rot0",
                "screenContext": try jsonObject(JSONEncoder().encode(context))
            ], screenshot: png)
    }

    func facts(_ frame: CapturedObservation) -> [String: Any] {
        guard let facts = frame.metadata["postActionStability"] as? [String: Any] else {
            XCTFail("Expected post-action stability metadata")
            return [:]
        }
        return facts
    }

    func phoneFrame(scale: Int = 1, patches: [(CGRect, [UInt8])] = []) throws -> CapturedObservation {
        let png = try screenPNG(
            width: 390 * scale, height: 844 * scale,
            patches: patches.map {
                (
                    CGRect(
                        x: $0.0.minX * Double(scale), y: $0.0.minY * Double(scale),
                        width: $0.0.width * Double(scale), height: $0.0.height * Double(scale)), $0.1
                )
            })
        return CapturedObservation(
            nodes: [],
            metadata: [
                "captureSource": "coredevice_screenshot",
                "displayRotation": "rot0", "displayID": 1, "nativeRotation": "rot0",
                "screenContext": try jsonObject(JSONEncoder().encode(screenTestContext()))
            ], screenshot: png)
    }

    func alternate(_ firstSample: CapturedObservation, _ secondSample: CapturedObservation) throws
        -> CapturedObservation {
        var time = 0.0, count = 0
        return try NativePostActionStability.capture(
            now: { time }, pause: { time += $0 }, checkCancellation: {},
            sample: { _ in
                time += 0.6; defer { count += 1 }
                return count.isMultiple(of: 2) ? firstSample : secondSample
            })
    }
}
