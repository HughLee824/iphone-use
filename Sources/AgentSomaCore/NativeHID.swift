import Foundation
import CoreGraphics
import Darwin

final class NativeCancellation {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
    func check() throws { if isCancelled { throw SomaError("native_cancelled", "Native session is closing") } }
}

struct NativeCoordinateMapper {
    // Coordinates are continuous screen points with a top-left origin. Original PNG
    // coordinates divide by the observation's pointScale before entering this mapper.
    static func map(_ point: CGPoint, screen: ScreenRect, rotation: String) throws -> (UInt16, UInt16) {
        guard screen.valid, point.x.isFinite, point.y.isFinite,
              point.x >= screen.x, point.y >= screen.y,
              point.x <= screen.x + screen.width, point.y <= screen.y + screen.height else {
            throw SomaError("invalid_screen_point", "Point is outside the source observation")
        }
        let x = (point.x - screen.x) / screen.width, y = (point.y - screen.y) / screen.height
        let mapped: (Double, Double)
        switch rotation {
        case "rot0": mapped = (x, y)
        case "rot90": mapped = (y, 1 - x)
        case "rot180": mapped = (1 - x, 1 - y)
        case "rot270": mapped = (1 - y, x)
        default: throw SomaError("native_orientation_unsupported", "Unknown display rotation")
        }
        return (UInt16((mapped.0 * 65535).rounded()), UInt16((mapped.1 * 65535).rounded()))
    }
}

struct NativeTouchReport {
    static func make(contact: Bool, x: UInt16, y: UInt16, timestamp: UInt64) -> Data {
        var bytes = [UInt8](repeating: 0, count: 58)
        bytes[0] = 9; bytes[1] = 1; bytes[2] = 5; bytes[3] = contact ? 0xc2 : 2
        bytes[4] = UInt8(x & 255); bytes[5] = UInt8(x >> 8)
        bytes[6] = UInt8(y & 255); bytes[7] = UInt8(y >> 8)
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

    init(gesture: CoordinateGesture) throws {
        try gesture.validate(kind: "swipe")
        guard let end = gesture.end, let motion = gesture.motion else { throw ScreenGuard.Failure.invalidGuard }
        let screen = gesture.screenGuard.context.screen
        start = try NativeCoordinateMapper.map(gesture.start, screen: screen, rotation: "rot0")
        self.end = try NativeCoordinateMapper.map(end, screen: screen, rotation: "rot0")
        self.motion = motion
        // Native velocity is measured in original screenshot pixels per second.
        let dx = (end.x - gesture.start.x) * Double(gesture.screenGuard.pixelWidth) / screen.width
        let dy = (end.y - gesture.start.y) * Double(gesture.screenGuard.pixelHeight) / screen.height
        movementDuration = max(Self.sampleInterval, hypot(dx, dy) / motion.velocity)
        guard motion.pressDuration + movementDuration + motion.holdDuration <= SwipeMotion.maximumEstimatedDuration else {
            throw SomaError("swipe_duration_exceeded", "Native swipe motion exceeds 10 seconds")
        }
    }

    func point(at fraction: Double) -> (UInt16, UInt16) {
        let t = min(1, max(0, fraction))
        return (UInt16((Double(start.0) + (Double(end.0) - Double(start.0)) * t).rounded()),
                UInt16((Double(start.1) + (Double(end.1) - Double(start.1)) * t).rounded()))
    }
}

final class NativeHIDAdapter {
    private let transport: NativeTransport
    private let cancellation: NativeCancellation
    private let clock: () -> UInt64
    private let wait: (TimeInterval) -> Void
    private let uptime: () -> TimeInterval
    private var surface: UInt64?
    private var contact: (UInt16, UInt16)?
    private(set) var releaseUncertain = false
    private var inputUncertain = false
    var isAvailable: Bool { surface != nil && contact == nil && !inputUncertain && !releaseUncertain && !cancellation.isCancelled }
    private static let feature = "com.apple.coredevice.feature.remote.universalhidservice"

    init(transport: NativeTransport, cancellation: NativeCancellation,
         clock: @escaping () -> UInt64 = { mach_absolute_time() },
         wait: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.transport = transport; self.cancellation = cancellation; self.clock = clock; self.wait = wait; self.uptime = uptime
    }
    func prepare() throws {
        let response = try transport.request(["featureIdentifier": Self.feature, "messageType": "Request",
                                               "payload": ["connectedServices": [:]]], timeout: 8)
        guard let services = response["connectedServices"] as? [[String: Any]] else {
            throw SomaError("native_hid_unsupported", "HID surface inventory missing")
        }
        let matches = services.filter { ($0["PrimaryUsagePage"] as? NSNumber)?.intValue == 13
            && ($0["PrimaryUsage"] as? NSNumber)?.intValue == 4 && $0["UniversalControlBuiltIn"] as? Bool == true }
        guard matches.count == 1, let identifier = matches[0]["_ServiceID"] as? NSNumber, identifier.uint64Value > 0 else {
            throw SomaError("native_hid_unsupported", "No unique built-in touchscreen surface")
        }
        surface = identifier.uint64Value
    }
    private func report(contact: Bool, point: (UInt16, UInt16), timeout: TimeInterval = 3) throws {
        guard let surface else { throw SomaError("native_hid_unavailable", "Touchscreen has not been negotiated") }
        try transport.send(["featureIdentifier": Self.feature, "messageType": "Request",
            "payload": ["send": ["_0": NativeTouchReport.make(contact: contact, x: point.0, y: point.1, timestamp: clock()),
                                   "_1": nativeUInt(surface)]]], timeout: timeout)
    }
    func tap(_ point: (UInt16, UInt16), hold: TimeInterval = 0.06) throws -> [String: Any] {
        try cancellation.check()
        guard isAvailable, hold.isFinite, (0.01...0.5).contains(hold) else {
            throw SomaError("native_hid_unavailable", "Touch state is unavailable; reconnect and observe")
        }
        let started = ProcessInfo.processInfo.systemUptime
        // Mark before sending: a failed write may have delivered CONTACT.
        contact = point
        do {
            try report(contact: true, point: point)
            let deadline = ProcessInfo.processInfo.systemUptime + hold
            while ProcessInfo.processInfo.systemUptime < deadline {
                try cancellation.check()
                wait(min(0.005, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
            }
            try cancellation.check()
            try report(contact: false, point: point)
            contact = nil
            return ["transportStatus": "sent", "verificationStatus": "not_checked",
                    "contactReleaseQueued": true, "hostStartedUptime": started,
                    "hostCompletedUptime": ProcessInfo.processInfo.systemUptime,
                    "hidX": Int(point.0), "hidY": Int(point.1),
                    "timestampSource": "mach_absolute_time_low48"]
        } catch {
            inputUncertain = true
            let cleanup = release()
            throw ActionFailure(code: "native_input_uncertain", description: "Touch may have been sent: \(error). Observe; do not replay automatically.",
                possiblyExecuted: true, requiresObservation: true,
                result: ["transportStatus": "uncertain", "verificationStatus": "uncertain", "cleanup": cleanup])
        }
    }
    func swipe(_ plan: NativeSwipePlan, checkHealth: () throws -> Void = {}) throws -> [String: Any] {
        try cancellation.check()
        guard isAvailable else { throw SomaError("native_hid_unavailable", "Touch state is unavailable; reconnect and observe") }
        try checkHealth()
        let started = uptime()
        let deadline = started + SwipeMotion.maximumEstimatedDuration
        var moves = 0
        var attempted = false
        func check() throws {
            try cancellation.check()
            try checkHealth()
            guard uptime() < deadline else { throw SomaError("native_input_deadline", "Native swipe exceeded its execution deadline") }
        }
        func waitUntil(_ target: TimeInterval) throws {
            while uptime() < target {
                try check()
                wait(min(0.005, max(0, target - uptime())))
            }
            try check()
        }
        func move(to point: (UInt16, UInt16)) throws {
            try check()
            // A failed MOVE may have arrived. Release at the last attempted position.
            contact = point
            attempted = true
            try report(contact: true, point: point, timeout: min(3, max(0.001, deadline - uptime())))
        }
        do {
            try move(to: plan.start)
            try waitUntil(uptime() + plan.motion.pressDuration)
            let movementStarted = uptime()
            var nextSample = min(NativeSwipePlan.sampleInterval, plan.movementDuration)
            while true {
                try waitUntil(movementStarted + nextSample)
                let elapsed = uptime() - movementStarted
                let fraction = uptime() >= movementStarted + plan.movementDuration ? 1 : min(1, elapsed / plan.movementDuration)
                try move(to: plan.point(at: fraction))
                moves += 1
                if fraction >= 1 { break }
                // Skip samples missed during a slow send; never emit a catch-up burst.
                let next = (floor((uptime() - movementStarted) / NativeSwipePlan.sampleInterval) + 1) * NativeSwipePlan.sampleInterval
                nextSample = min(plan.movementDuration, max(nextSample + NativeSwipePlan.sampleInterval, next))
            }
            try waitUntil(uptime() + plan.motion.holdDuration)
            try report(contact: false, point: plan.end, timeout: min(3, max(0.001, deadline - uptime())))
            contact = nil
            return ["transportStatus": "sent", "verificationStatus": "not_checked", "contactReleaseQueued": true,
                    "motion": plan.motion.result, "motionVelocityUnit": "original_screenshot_pixels_per_second",
                    "plannedMovementDuration": plan.movementDuration, "moveReportsQueued": moves,
                    "hostStartedUptime": started, "hostCompletedUptime": uptime(),
                    "hidStart": [Int(plan.start.0), Int(plan.start.1)], "hidEnd": [Int(plan.end.0), Int(plan.end.1)],
                    "timestampSource": "mach_absolute_time_low48"]
        } catch {
            guard attempted else { throw error }
            inputUncertain = true
            let cleanup = release()
            throw ActionFailure(code: "native_input_uncertain", description: "Swipe may have been sent: \(error). Observe; do not replay automatically.",
                possiblyExecuted: true, requiresObservation: true,
                result: ["transportStatus": "uncertain", "verificationStatus": "uncertain", "cleanup": cleanup,
                         "motion": plan.motion.result, "moveReportsQueued": moves])
        }
    }
    func release() -> [String: Any] {
        guard let point = contact else { return ["releaseRequired": false, "releaseUncertain": releaseUncertain] }
        contact = nil
        do {
            // Deliberately independent of cancellation, but never opens a replacement connection.
            try report(contact: false, point: point)
            return ["releaseRequired": true, "releaseQueued": true, "releaseUncertain": false]
        } catch {
            releaseUncertain = true
            return ["releaseRequired": true, "releaseQueued": false, "releaseUncertain": true, "error": String(describing: error)]
        }
    }
}
