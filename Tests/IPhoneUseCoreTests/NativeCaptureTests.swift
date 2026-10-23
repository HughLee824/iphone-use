import XCTest
import CoreVideo
import ImageIO
@testable import IPhoneUseCore

final class NativeCaptureTests: XCTestCase {

    func display(_ rotation: String = "rot0", backlight: String = "activeOn") -> [String: Any] {
        [
            "backlightState": backlight,
            "displays": [
                [
                    "primary": true, "displayId": 1,
                    "bounds": [[0, 0], [12, 18]], "pointScale": 3,
                    "currentOrientation": rotation, "nativeOrientation": "rot0"
                ]
            ]
        ]
    }
    final class State {
        let lock = NSLock()
        var screenshots = 0
        var finalPhase = false
    }

    func pixels(width: Int = 16, height: Int = 24) throws -> CVPixelBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixels),
            kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetBytesPerRow(buffer) * height)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
}
