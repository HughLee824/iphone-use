import Foundation
import CoreGraphics
import Darwin

extension NativeHIDAdapter {
    private func keyboardRequest(_ payload: [String: Any]) throws -> [String: Any] {
        try transport.request(
            ["featureIdentifier": Self.feature, "messageType": "Request", "payload": payload], timeout: 8)
    }
    private func keyboardInventory() throws -> [[String: Any]] {
        guard
            let services = try keyboardRequest(["connectedServices": [:]])["connectedServices"]
                as? [[String: Any]]
        else {
            throw IPhoneUseError("native_keyboard_ownership_unknown", "HID inventory is unavailable")
        }
        return services
    }
    func prepareKeyboard() throws {
        try cancellation.check()
        guard isAvailable else {
            throw IPhoneUseError("native_hid_unavailable", "Reconnect and observe before typing")
        }
        if keyboardReady { return }
        do {
            // Borrow the advertised CoreDevice keyboard. Registering a new HID keyboard
            // changes iOS hardware-keyboard state and can hide an app's entire composer.
            keyboardID = try NativeKeyboard.builtInService(in: keyboardInventory())
            keyboardReady = true
            keyboardCleanup = nil
        } catch {
            throw ActionFailure(
                code: "native_keyboard_unavailable", description: String(describing: error),
                possiblyExecuted: false,
                requiresObservation: true, result: ["recovery": NativeRecovery.resolveError.result])
        }
    }
    func sendKeys(_ keys: [UInt8]) throws {
        guard let keyboardID else {
            throw IPhoneUseError("native_keyboard_unavailable", "CoreDevice keyboard has not been discovered")
        }
        try transport.send(
            [
                "featureIdentifier": Self.feature, "messageType": "Request",
                "payload": [
                    "send": [
                        "_0": NativeKeyboard.report(keys, timestamp: clock()), "_1": nativeUInt(keyboardID)
                    ]
                ]
            ], timeout: 3)
    }
    func type(
        _ keySets: [[UInt8]], mode: String = "insert", checkHealth: () throws -> Void = {}
    ) throws -> [String: Any] {
        let editingKeys = try NativeKeyboard.editingKeys(mode: mode)
        try cancellation.check()
        guard isAvailable, keyboardReady, !keySets.isEmpty, keySets.count <= NativeKeyboard.maximumCharacters
        else {
            throw IPhoneUseError(
                "native_keyboard_unavailable",
                "Prepare the native keyboard and observe the focused field before typing"
            )
        }
        try checkHealth()
        var attempted = false, completed = 0, editingAttempted = false, editingQueued = false
        let started = uptime()
        do {
            for (index, keys) in (editingKeys + keySets).enumerated() {
                try cancellation.check(); try checkHealth()
                guard uptime() - started < 10 else {
                    throw IPhoneUseError("native_input_deadline", "Native typing exceeded ten seconds")
                }
                attempted = true; keysDown = true // Mark before send; a failure may follow device delivery.
                if index < editingKeys.count { editingAttempted = true }
                // Establish modifiers before the character. The device processes usage
                // transitions in order; a combined Shift+character report can type unshifted.
                let modifiers = keys.filter { (0xe0...0xe7).contains($0) }
                if !modifiers.isEmpty { try sendKeys(modifiers); try pauseKeyboard(checkHealth: checkHealth) }
                try sendKeys(keys)
                try pauseKeyboard(checkHealth: checkHealth)
                try sendKeys([]); keysDown = false
                if index < editingKeys.count { editingQueued = true } else { completed += 1 }
                try pauseKeyboard(checkHealth: checkHealth)
            }
            return [
                "transportStatus": "sent", "verificationStatus": "not_checked", "charactersQueued": completed,
                "keyboardReleaseQueued": true, "focusConfirmed": false, "layoutConfirmed": false,
                "textMode": mode, "editingShortcutQueued": editingQueued, "editingEffectConfirmed": false,
                "hostStartedUptime": started, "hostCompletedUptime": uptime()
            ]
        } catch {
            guard attempted else { throw error }
            inputUncertain = true
            throw ActionFailure(
                code: "native_input_uncertain",
                description: "Text may be partially entered: \(error). Observe; do not replay.",
                possiblyExecuted: true, requiresObservation: true,
                result: [
                    "transportStatus": "uncertain", "verificationStatus": "uncertain",
                    "charactersQueued": completed,
                    "textMode": mode, "editingShortcutAttempted": editingAttempted,
                    "editingShortcutQueued": editingQueued,
                    "editingEffectConfirmed": false, "cleanup": release()
                ])
        }
    }
    private func pauseKeyboard(checkHealth: () throws -> Void) throws {
        let until = uptime() + 0.025
        while uptime() < until {
            try cancellation.check(); try checkHealth(); wait(min(0.005, max(0, until - uptime())))
        }
        try cancellation.check(); try checkHealth()
    }

    func press(_ key: NativePressKey, checkHealth: () throws -> Void = {}) throws -> [String: Any] {
        func facts(_ value: [String: Any], queued: Any) -> [String: Any] {
            var result = value
            for key in [
                "charactersQueued", "textMode", "editingShortcutAttempted", "editingShortcutQueued",
                "editingEffectConfirmed"
            ] {
                result.removeValue(forKey: key)
            }
            result["key"] = key.rawValue
            result["keyReportQueued"] = queued
            result["keyEffectConfirmed"] = false
            return result
        }
        do {
            // The focused app interprets this usage; no caret/focus effect is inferred.
            return facts(try type([key.usages], checkHealth: checkHealth), queued: true)
        } catch let failure as ActionFailure {
            throw ActionFailure(
                code: failure.code,
                description: "\(key.rawValue) may have changed the focused app: \(failure.description)",
                possiblyExecuted: failure.possiblyExecuted,
                requiresObservation: failure.requiresObservation,
                result: facts(failure.result ?? [:], queued: "unknown"))
        }
    }
    func paste(mode: String = "insert", checkHealth: () throws -> Void = {}) throws -> [String: Any] {
        do {
            // Left GUI, V; modifier precedes key.
            var result = try type([[0xe3, 0x19]], mode: mode, checkHealth: checkHealth)
            result.removeValue(forKey: "charactersQueued")
            result["pasteShortcutQueued"] = true
            result["textCommitConfirmed"] = false
            return result
        } catch let failure as ActionFailure {
            var result = failure.result ?? [:]
            result.removeValue(forKey: "charactersQueued")
            result["pasteShortcutQueued"] = "unknown"
            throw ActionFailure(
                code: failure.code, description: failure.description,
                possiblyExecuted: failure.possiblyExecuted,
                requiresObservation: failure.requiresObservation, result: result)
        }
    }
    func clearText(checkHealth: () throws -> Void = {}) throws -> [String: Any] {
        do {
            var result = try type([[0x2a]], mode: "replace", checkHealth: checkHealth) // Delete selected content.
            result.removeValue(forKey: "charactersQueued")
            result["deleteShortcutQueued"] = true
            result["textCommitConfirmed"] = false
            return result
        } catch let failure as ActionFailure {
            var result = failure.result ?? [:]
            result.removeValue(forKey: "charactersQueued")
            result["deleteShortcutQueued"] = "unknown"
            throw ActionFailure(
                code: failure.code, description: failure.description,
                possiblyExecuted: failure.possiblyExecuted,
                requiresObservation: failure.requiresObservation, result: result)
        }
    }
    func closeKeyboard() -> [String: Any] {
        if let keyboardCleanup { return keyboardCleanup }
        // This service belongs to iOS, not this session. Never remove it. The caller
        // releases our pending keys first; retain its ID for uncertain-release cleanup.
        let result: [String: Any] = [
            "keyboardRemoveAcknowledged": true,
            "keyboardRemovalRequired": false, "keyboardServiceSource": "coredevice_builtin"
        ]
        keyboardReady = false; keyboardCleanup = result
        return result
    }
}
