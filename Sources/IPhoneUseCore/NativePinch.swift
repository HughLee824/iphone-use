import Foundation
import CoreGraphics

struct NativePinchPlan {
    let start: [(UInt16, UInt16)]
    let end: [(UInt16, UInt16)]
    let motion: PinchMotion
    init(gesture: CoordinateGesture, rotation: String) throws {
        try gesture.validate(kind: "pinch")
        guard let motion = gesture.pinch else { throw ScreenGuard.Failure.invalidGuard }
        self.motion = motion
        let screen = gesture.screenGuard.context.screen
        start = try motion.points(center: gesture.start, ending: false).map { try NativeCoordinateMapper.map($0, screen: screen, rotation: rotation) }
        end = try motion.points(center: gesture.start, ending: true).map { try NativeCoordinateMapper.map($0, screen: screen, rotation: rotation) }
    }
    func points(at fraction: Double) -> [(UInt16, UInt16)] {
        let t = min(1, max(0, fraction))
        return zip(start, end).map { a, b in
            (UInt16((Double(a.0) + (Double(b.0) - Double(a.0)) * t).rounded()),
             UInt16((Double(a.1) + (Double(b.1) - Double(a.1)) * t).rounded()))
        }
    }
}

struct NativePinchReport {
    // Apple UniversalHID DigitizerReport: five 40-bit slots at byte 3;
    // slot index uses bits 0...4, touch/range bits 6/7, identities at byte 40.
    // Read-only Apple decoder evidence: apple-native-pinch-20260921/decoder.txt.
    // Release includes both slots/identities with touch/range cleared.
    static func make(contact: Bool, points: [(UInt16, UInt16)], timestamp: UInt64) -> Data {
        precondition(points.count == 2)
        var bytes = [UInt8](repeating: 0, count: 58)
        bytes[0] = 9; bytes[1] = 2; bytes[2] = 5
        for (slot, point) in points.enumerated() {
            let offset = 3 + slot * 5, identity = UInt8(slot + 2)
            bytes[offset] = identity | (contact ? 0xc0 : 0)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: point.0)
            bytes[offset + 2] = UInt8(point.0 >> 8)
            bytes[offset + 3] = UInt8(truncatingIfNeeded: point.1)
            bytes[offset + 4] = UInt8(point.1 >> 8)
            bytes[40 + slot] = identity
        }
        // Unlike the legacy single-contact sample, use the decoder's full timestamp field.
        for index in 0..<8 { bytes[45 + index] = UInt8(truncatingIfNeeded: timestamp >> (8 * index)) }
        return Data(bytes)
    }
}
