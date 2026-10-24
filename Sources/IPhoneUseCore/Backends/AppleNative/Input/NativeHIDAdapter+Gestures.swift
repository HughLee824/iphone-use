import Foundation
import CoreGraphics
import Darwin

extension NativeHIDAdapter {
    func tap(
        _ point: (UInt16, UInt16), hold: TimeInterval = 0.06, onContact: () -> Void = {},
        checkHealth: () throws -> Void = {}
    ) throws -> [String: Any] {
        try cancellation.check()
        guard isAvailable, hold.isFinite, (0.01...5).contains(hold) else {
            throw IPhoneUseError("native_hid_unavailable", "Touch state is unavailable; reconnect and observe")
        }
        try checkHealth()
        let started = uptime()
        let inputDeadline = started + SwipeMotion.maximumEstimatedDuration
        func check() throws {
            try cancellation.check()
            try checkHealth()
            guard uptime() < inputDeadline else {
                throw IPhoneUseError("native_input_deadline", "Native touch exceeded its execution deadline")
            }
        }
        // Mark before sending: a failed write may have delivered CONTACT.
        contact = point
        do {
            try report(contact: true, point: point)
            onContact()
            let deadline = uptime() + hold
            while uptime() < deadline {
                try check()
                wait(min(0.005, max(0, deadline - uptime())))
            }
            try check()
            try report(contact: false, point: point, timeout: min(3, max(0.001, inputDeadline - uptime())))
            contact = nil
            return [
                "transportStatus": "sent", "verificationStatus": "not_checked", "contactReleaseQueued": true,
                "hostStartedUptime": started, "hostCompletedUptime": uptime(), "pressDuration": hold,
                "hidX": Int(point.0), "hidY": Int(point.1), "timestampSource": "mach_absolute_time_low48"
            ]
        } catch {
            inputUncertain = true
            let cleanup = release()
            throw ActionFailure(
                code: "native_input_uncertain",
                description: "Touch may have been sent: \(error). Observe; do not replay automatically.",
                possiblyExecuted: true, requiresObservation: true,
                result: ["transportStatus": "uncertain", "verificationStatus": "uncertain", "cleanup": cleanup])
        }
    }
    func doubleTap(_ point: (UInt16, UInt16), onContact: () -> Void = {}, checkHealth: () throws -> Void = {}) throws
        -> [String: Any] {
        try cancellation.check()
        guard isAvailable else {
            throw IPhoneUseError("native_hid_unavailable", "Touch state is unavailable; reconnect and observe")
        }
        try checkHealth()
        let started = uptime(), deadline = started + 0.6
        let hold = 0.06, gap = 0.10, secondDownDeadline = started + 0.30
        var attempted = 0, queued = 0
        var downTimes: [TimeInterval] = []
        func check() throws {
            try checkDoubleTap(deadline: deadline, checkHealth: checkHealth)
        }
        do {
            for index in 0..<2 {
                try check()
                // Never turn a delayed sequence into an unrelated second tap.
                guard index == 0 || uptime() < secondDownDeadline else {
                    throw IPhoneUseError("native_input_deadline", "Second contact missed the double-tap timing window")
                }
                contact = point // A failed send may still have delivered contact.
                attempted += 1
                downTimes.append(uptime())
                let contactDeadline = index == 0 ? secondDownDeadline : deadline
                try report(contact: true, point: point, timeout: max(0.001, contactDeadline - uptime()))
                if index == 0 { onContact() }
                try waitUntil(uptime() + hold, check: check)
                try report(contact: false, point: point, timeout: max(0.001, deadline - uptime()))
                contact = nil
                queued += 1
                if index == 0 { try waitUntil(uptime() + gap, check: check) }
            }
            try check()
            var result = doubleTapFacts(
                point, started: started, attempted: attempted, queued: queued, downTimes: downTimes)
            result["transportStatus"] = "sent"
            result["verificationStatus"] = "not_checked"
            result["contactReleaseQueued"] = true
            return result
        } catch {
            guard attempted > 0 else { throw error }
            inputUncertain = true
            var result = doubleTapFacts(
                point, started: started, attempted: attempted, queued: queued, downTimes: downTimes)
            result["transportStatus"] = "uncertain"
            result["verificationStatus"] = "uncertain"
            result["cleanup"] = release()
            throw ActionFailure(
                code: "native_input_uncertain",
                description: "Double tap may be partially delivered: \(error). Observe; do not replay automatically.",
                possiblyExecuted: true, requiresObservation: true, result: result)
        }
    }
    func swipe(_ plan: NativeSwipePlan, onContact: () -> Void = {}, checkHealth: () throws -> Void = {}) throws
        -> [String: Any] {
        try cancellation.check()
        guard isAvailable else {
            throw IPhoneUseError("native_hid_unavailable", "Touch state is unavailable; reconnect and observe")
        }
        try checkHealth()
        let started = uptime()
        let deadline = started + SwipeMotion.maximumEstimatedDuration
        var moves = 0
        var attempted = false
        func check() throws {
            try cancellation.check()
            try checkHealth()
            guard uptime() < deadline else {
                throw IPhoneUseError("native_input_deadline", "Native swipe exceeded its execution deadline")
            }
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
            onContact()
            try waitUntil(uptime() + plan.motion.pressDuration, check: check)
            try moveSwipe(plan, moves: &moves, move: move, waitUntil: { try self.waitUntil($0, check: check) })
            try waitUntil(uptime() + plan.motion.holdDuration, check: check)
            try report(contact: false, point: plan.end, timeout: min(3, max(0.001, deadline - uptime())))
            contact = nil
            return swipeFacts(plan, moves: moves, started: started)
        } catch {
            guard attempted else { throw error }
            inputUncertain = true
            let cleanup = release()
            throw ActionFailure(
                code: "native_input_uncertain",
                description: "Swipe may have been sent: \(error). Observe; do not replay automatically.",
                possiblyExecuted: true, requiresObservation: true,
                result: [
                    "transportStatus": "uncertain", "verificationStatus": "uncertain", "cleanup": cleanup,
                    "motion": plan.motion.result, "moveReportsQueued": moves
                ])
        }
    }
    func pinchReport(contact: Bool, points: [(UInt16, UInt16)], timeout: TimeInterval) throws {
        guard let surface else { throw IPhoneUseError("native_hid_unavailable", "Touchscreen has not been negotiated") }
        try transport.send(
            [
                "featureIdentifier": Self.feature, "messageType": "Request",
                "payload": [
                    "send": [
                        "_0": NativePinchReport.make(contact: contact, points: points, timestamp: clock()),
                        "_1": nativeUInt(surface)
                    ]
                ]
            ], timeout: timeout)
    }
    func pinch(_ plan: NativePinchPlan, onContact: () -> Void = {}, checkHealth: () throws -> Void = {}) throws
        -> [String: Any] {
        try cancellation.check()
        guard isAvailable else {
            throw IPhoneUseError("native_hid_unavailable", "Touch state is unavailable; reconnect and observe")
        }
        try checkHealth()
        let started = uptime(), deadline = started + 6
        var attempted = false, moves = 0
        func check() throws {
            try cancellation.check()
            try checkHealth()
            guard uptime() < deadline else {
                throw IPhoneUseError("native_input_deadline", "Pinch exceeded six seconds")
            }
        }
        func waitUntil(_ target: TimeInterval) throws { try self.waitUntil(target, check: check) }
        func move(_ points: [(UInt16, UInt16)]) throws {
            try check()
            // A send failure can follow delivery. Retain both identities/positions for release.
            pinchContacts = points
            attempted = true
            try pinchReport(contact: true, points: points, timeout: min(3, max(0.001, deadline - uptime())))
        }
        do {
            try move(plan.start)
            onContact()
            try waitUntil(uptime() + 0.06)
            try movePinch(plan, moves: &moves, move: move, waitUntil: waitUntil)
            try waitUntil(uptime() + 0.06)
            try pinchReport(contact: false, points: plan.end, timeout: min(3, max(0.001, deadline - uptime())))
            pinchContacts = nil
            try check()
            return [
                "transportStatus": "sent", "verificationStatus": "not_checked", "contactReleaseQueued": true,
                "contactCount": 2, "motion": plan.motion.result, "moveReportsQueued": moves,
                "hostStartedUptime": started, "hostCompletedUptime": uptime(), "timestampSource": "mach_absolute_time",
                "hidStart": plan.start.map { [Int($0.0), Int($0.1)] }, "hidEnd": plan.end.map { [Int($0.0), Int($0.1)] }
            ]
        } catch {
            guard attempted else { throw error }
            inputUncertain = true
            throw ActionFailure(
                code: "native_input_uncertain",
                description: "Pinch may be partially delivered: \(error). Observe; do not replay.",
                possiblyExecuted: true, requiresObservation: true,
                result: [
                    "transportStatus": "uncertain", "verificationStatus": "uncertain", "contactCount": 2,
                    "motion": plan.motion.result, "moveReportsQueued": moves, "cleanup": release()
                ])
        }
    }
    private func waitUntil(_ target: TimeInterval, check: () throws -> Void) throws {
        while uptime() < target {
            try check()
            wait(min(0.005, max(0, target - uptime())))
        }
        try check()
    }
    private func doubleTapFacts(
        _ point: (UInt16, UInt16), started: Double, attempted: Int, queued: Int, downTimes: [Double]
    ) -> [String: Any] {
        [
            "contactsAttempted": attempted, "tapPairsQueued": queued, "hostDownUptimes": downTimes,
            "hostStartedUptime": started, "hostCompletedUptime": uptime(), "pressDuration": 0.06,
            "interTapReleaseGap": 0.10, "maximumDownInterval": 0.30, "hidX": Int(point.0), "hidY": Int(point.1),
            "timestampSource": "mach_absolute_time_low48"
        ]
    }

    private func moveSwipe(
        _ plan: NativeSwipePlan, moves: inout Int, move: ((UInt16, UInt16)) throws -> Void,
        waitUntil: (TimeInterval) throws -> Void
    ) throws {
        let movementStarted = uptime()
        var nextSample = min(NativeSwipePlan.sampleInterval, plan.movementDuration)
        while true {
            try waitUntil(movementStarted + nextSample)
            let elapsed = uptime() - movementStarted
            let fraction =
                uptime() >= movementStarted + plan.movementDuration ? 1 : min(1, elapsed / plan.movementDuration)
            try move(plan.point(at: fraction))
            moves += 1
            if fraction >= 1 { break }
            // Skip samples missed during a slow send; never emit a catch-up burst.
            let next =
                (floor((uptime() - movementStarted) / NativeSwipePlan.sampleInterval) + 1)
                * NativeSwipePlan.sampleInterval
            nextSample = min(plan.movementDuration, max(nextSample + NativeSwipePlan.sampleInterval, next))
        }
    }

    private func movePinch(
        _ plan: NativePinchPlan, moves: inout Int, move: ([(UInt16, UInt16)]) throws -> Void,
        waitUntil: (TimeInterval) throws -> Void
    ) throws {
        let moving = uptime(), interval = NativeSwipePlan.sampleInterval
        var next = min(interval, plan.motion.duration)
        while true {
            try waitUntil(moving + next)
            let fraction =
                uptime() >= moving + plan.motion.duration ? 1 : min(1, (uptime() - moving) / plan.motion.duration)
            try move(plan.points(at: fraction))
            moves += 1
            if fraction >= 1 { break }
            next = min(
                plan.motion.duration, max(next + interval, (floor((uptime() - moving) / interval) + 1) * interval))
        }
    }
    private func swipeFacts(_ plan: NativeSwipePlan, moves: Int, started: TimeInterval) -> [String: Any] {
        return [
            "transportStatus": "sent", "verificationStatus": "not_checked", "contactReleaseQueued": true,
            "motion": plan.motion.result, "motionVelocityUnit": "original_screenshot_pixels_per_second",
            "plannedMovementDuration": plan.movementDuration, "moveReportsQueued": moves, "hostStartedUptime": started,
            "hostCompletedUptime": uptime(), "hidStart": [Int(plan.start.0), Int(plan.start.1)],
            "hidEnd": [Int(plan.end.0), Int(plan.end.1)], "timestampSource": "mach_absolute_time_low48"
        ]
    }

    private func checkDoubleTap(deadline: TimeInterval, checkHealth: () throws -> Void) throws {
            try cancellation.check()
            try checkHealth()
            guard uptime() < deadline else {
                throw IPhoneUseError("native_input_deadline", "Double tap exceeded its execution deadline")
            }
    }

}
