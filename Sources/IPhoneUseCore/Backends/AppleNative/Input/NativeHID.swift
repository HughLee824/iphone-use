import IPhoneUseRunnerSupport
import Foundation
import CoreGraphics
import Darwin

final class NativeCancellation {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
    func check() throws {
        if isCancelled { throw IPhoneUseError("native_cancelled", "Native session is closing") }
    }
}

struct NativeCoordinateMapper {
    // Coordinates are continuous screen points with a top-left origin. Original PNG
    // coordinates divide by the observation's pointScale before entering this mapper.
    static func map(_ point: CGPoint, screen: ScreenRect, rotation: String) throws -> (UInt16, UInt16) {
        guard screen.valid, point.x.isFinite, point.y.isFinite,
            point.x >= screen.originX, point.y >= screen.originY,
            point.x <= screen.originX + screen.width, point.y <= screen.originY + screen.height
        else {
            throw IPhoneUseError("invalid_screen_point", "Point is outside the source observation")
        }
        let column = (point.x - screen.originX) / screen.width,
            row = (point.y - screen.originY) / screen.height
        let mapped: (Double, Double)
        switch rotation {
        case "rot0": mapped = (column, row)
        case "rot90": mapped = (row, 1 - column)
        case "rot180": mapped = (1 - column, 1 - row)
        case "rot270": mapped = (1 - row, column)
        default: throw IPhoneUseError("native_orientation_unsupported", "Unknown display rotation")
        }
        return (UInt16((mapped.0 * 65535).rounded()), UInt16((mapped.1 * 65535).rounded()))
    }
}

struct NativeTouchReport {
    static func make(contact: Bool, x column: UInt16, y row: UInt16, timestamp: UInt64) -> Data {
        var bytes = [UInt8](repeating: 0, count: 58)
        bytes[0] = 9; bytes[1] = 1; bytes[2] = 5; bytes[3] = contact ? 0xc2 : 2
        bytes[4] = UInt8(column & 255); bytes[5] = UInt8(column >> 8)
        bytes[6] = UInt8(row & 255); bytes[7] = UInt8(row >> 8)
        bytes[40] = 2
        for index in 0..<6 { bytes[44 + index] = UInt8(truncatingIfNeeded: timestamp >> (8 * index)) }
        return Data(bytes)
    }
}

struct NativeSwipePlan {
    let start: (UInt16, UInt16)
    let end: (UInt16, UInt16)
    let motion: SwipeMotion
    let movementDuration: TimeInterval
    static let sampleInterval: TimeInterval = 1.0 / 60

    init(gesture: CoordinateGesture, rotation: String = "rot0") throws {
        try gesture.validate(kind: "swipe")
        guard let end = gesture.end, let motion = gesture.motion else {
            throw ScreenGuard.Failure.invalidGuard
        }
        let screen = gesture.screenGuard.context.screen
        start = try NativeCoordinateMapper.map(gesture.start, screen: screen, rotation: rotation)
        self.end = try NativeCoordinateMapper.map(end, screen: screen, rotation: rotation)
        self.motion = motion
        // Native velocity is measured in original screenshot pixels per second.
        let offsetX = (end.x - gesture.start.x) * Double(gesture.screenGuard.pixelWidth) / screen.width
        let offsetY = (end.y - gesture.start.y) * Double(gesture.screenGuard.pixelHeight) / screen.height
        movementDuration = max(Self.sampleInterval, hypot(offsetX, offsetY) / motion.velocity)
        guard
            motion.pressDuration + movementDuration + motion.holdDuration
                <= SwipeMotion.maximumEstimatedDuration
        else {
            throw IPhoneUseError("swipe_duration_exceeded", "Native swipe motion exceeds 10 seconds")
        }
    }

    func point(at fraction: Double) -> (UInt16, UInt16) {
        let progress = min(1, max(0, fraction))
        return (
            UInt16((Double(start.0) + (Double(end.0) - Double(start.0)) * progress).rounded()),
            UInt16((Double(start.1) + (Double(end.1) - Double(start.1)) * progress).rounded())
        )
    }
}

final class NativeHIDAdapter {
    enum State: String {
        case ready, unprepared, cancelled
        case contactActive = "contact_active", inputUncertain = "input_uncertain", releaseUncertain =
            "release_uncertain"
    }
    let transport: NativeTransport
    let cancellation: NativeCancellation
    let clock: () -> UInt64
    let wait: (TimeInterval) -> Void
    let uptime: () -> TimeInterval
    var surface: UInt64?
    var contact: (UInt16, UInt16)?
    var pinchContacts: [(UInt16, UInt16)]?
    var releaseUncertain = false
    var inputUncertain = false
    var keyboardID: UInt64?
    var keyboardReady = false
    var buttonTransport: NativeTransport?
    var homeDown = false
    var keysDown = false
    var keyboardCleanup: [String: Any]?
    var canType: Bool { isAvailable }
    var keyboardStatus: [String: Any] {
        [
            "prepared": keyboardReady, "keysMayBeDown": keysDown,
            "serviceMayExist": false, "serviceSource": "coredevice_builtin",
            "layout": "US usage mapping; active device layout unverified"
        ]
    }
    var state: State {
        if releaseUncertain { return .releaseUncertain }
        if inputUncertain { return .inputUncertain }
        if cancellation.isCancelled { return .cancelled }
        if contact != nil || pinchContacts != nil || keysDown || homeDown { return .contactActive }
        return surface == nil ? .unprepared : .ready
    }
    var isAvailable: Bool { state == .ready }
    static let feature = "com.apple.coredevice.feature.remote.universalhidservice"

    init(
        transport: NativeTransport, cancellation: NativeCancellation,
        clock: @escaping () -> UInt64 = { mach_absolute_time() },
        wait: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.transport = transport; self.cancellation = cancellation; self.clock = clock; self.wait = wait
        self.uptime = uptime
    }
    func prepare() throws {
        let response = try transport.request(
            [
                "featureIdentifier": Self.feature, "messageType": "Request",
                "payload": ["connectedServices": [:]]
            ], timeout: 8)
        guard let services = response["connectedServices"] as? [[String: Any]] else {
            throw IPhoneUseError("native_hid_unsupported", "HID surface inventory missing")
        }
        let matches = services.filter {
            ($0["PrimaryUsagePage"] as? NSNumber)?.intValue == 13
                && ($0["PrimaryUsage"] as? NSNumber)?.intValue == 4
                && $0["UniversalControlBuiltIn"] as? Bool == true
        }
        guard matches.count == 1, let identifier = matches[0]["_ServiceID"] as? NSNumber,
            identifier.uint64Value > 0
        else {
            throw IPhoneUseError("native_hid_unsupported", "No unique built-in touchscreen surface")
        }
        surface = identifier.uint64Value
    }
    func report(contact: Bool, point: (UInt16, UInt16), timeout: TimeInterval = 3) throws {
        guard let surface else {
            throw IPhoneUseError("native_hid_unavailable", "Touchscreen has not been negotiated")
        }
        try transport.send(
            [
                "featureIdentifier": Self.feature, "messageType": "Request",
                "payload": [
                    "send": [
                        "_0": NativeTouchReport.make(
                            contact: contact, x: point.0, y: point.1, timestamp: clock()),
                        "_1": nativeUInt(surface)
                    ]
                ]
            ], timeout: timeout)
    }
}
