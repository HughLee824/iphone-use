import Foundation
import CoreGraphics
import Darwin

extension NativeHIDAdapter {
    // System button events use the separate, paired CoreDevice Indigo service.
    // Queuing the event does not establish that SpringBoard handled it.
    private func homeEvent(state: UInt64) throws {
        guard let buttonTransport else {
            throw IPhoneUseError("native_hid_unavailable", "Home service is unavailable")
        }
        try buttonTransport.send(
            [
                "featureIdentifier": "com.apple.coredevice.feature.remote.hid.button",
                "messageType": "IndigoButtonEvent",
                "payload": [
                    "state": nativeUInt(state),
                    "usagePage": nativeUInt(0x0c), "usageCode": nativeUInt(0x40)
                ]
            ], timeout: 3)
    }
    func home(using transport: NativeTransport, checkHealth: () throws -> Void = {}) throws -> [String: Any] {
        try cancellation.check()
        guard isAvailable else {
            throw IPhoneUseError(
                "native_hid_unavailable", "Input state is unavailable; reconnect and observe")
        }
        try checkHealth()
        buttonTransport = transport
        let started = uptime()
        homeDown = true // A failed write may still have delivered the down event.
        do {
            try homeEvent(state: 1)
            let deadline = uptime() + 0.06
            while uptime() < deadline {
                try cancellation.check(); try checkHealth()
                wait(min(0.005, max(0, deadline - uptime())))
            }
            try cancellation.check(); try checkHealth()
            try homeEvent(state: 2)
            homeDown = false
            return [
                "transportStatus": "sent", "verificationStatus": "not_checked",
                "button": "home", "buttonReleaseQueued": true,
                "hostStartedUptime": started, "hostCompletedUptime": uptime()
            ]
        } catch {
            inputUncertain = true
            let cleanup = release()
            throw ActionFailure(
                code: "native_input_uncertain",
                description: "Home may have been sent: \(error). Observe; do not replay automatically.",
                possiblyExecuted: true, requiresObservation: true,
                result: [
                    "transportStatus": "uncertain", "verificationStatus": "uncertain", "cleanup": cleanup
                ])
        }
    }
    func release() -> [String: Any] {
        var keyboardFacts: [String: Any] = ["keyboardReleaseRequired": keysDown]
        keyboardFacts["buttonReleaseRequired"] = homeDown
        if homeDown {
            homeDown = false
            // Cleanup uses this exact connection even after cancellation.
            do { try homeEvent(state: 2); keyboardFacts["buttonReleaseQueued"] = true } catch {
                releaseUncertain = true; keyboardFacts["buttonReleaseQueued"] = false
                keyboardFacts["buttonReleaseError"] = String(describing: error)
            }
        }
        if keysDown {
            keysDown = false
            do { try sendKeys([]); keyboardFacts["keyboardReleaseQueued"] = true } catch {
                releaseUncertain = true; keyboardFacts["keyboardReleaseQueued"] = false
                keyboardFacts["keyboardReleaseError"] = String(describing: error)
            }
        }
        if let points = pinchContacts {
            pinchContacts = nil
            // One frame releases both contacts on the exact existing connection, even when cancelled.
            keyboardFacts["releaseRequired"] = true
            keyboardFacts["contactsToRelease"] = 2
            do {
                try pinchReport(contact: false, points: points, timeout: 3)
                keyboardFacts["releaseQueued"] = true
            } catch {
                releaseUncertain = true; keyboardFacts["releaseQueued"] = false
                keyboardFacts["error"] = String(describing: error)
            }
            keyboardFacts["releaseUncertain"] = releaseUncertain
            return keyboardFacts
        }
        guard let point = contact else {
            return keyboardFacts.merging(["releaseRequired": false, "releaseUncertain": releaseUncertain]) { _, new in
                new
            }
        }
        contact = nil
        do {
            // Deliberately independent of cancellation, but never opens a replacement connection.
            try report(contact: false, point: point)
            return keyboardFacts.merging([
                "releaseRequired": true, "releaseQueued": true, "releaseUncertain": releaseUncertain
            ]) { _, new in new }
        } catch {
            releaseUncertain = true
            return keyboardFacts.merging([
                "releaseRequired": true, "releaseQueued": false, "releaseUncertain": true,
                "error": String(describing: error)
            ]) { _, new in new }
        }
    }
}
