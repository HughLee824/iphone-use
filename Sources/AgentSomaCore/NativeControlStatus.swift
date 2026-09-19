import Foundation

enum NativeRecovery: String {
    case none, observe, inspectObservation = "inspect_observation"
    case reconnectAndObserve = "reconnect_and_observe"
    case checkMediaAndObserve = "check_media_and_observe"
    case resolveError = "resolve_error"
    case checkSession = "check_session"

    var result: [String: Any] {
        let message: String
        switch self {
        case .none: message = "No control recovery is needed; input still requires a current observation."
        case .observe: message = "Resolve any capture prerequisite, then observe again and decide on a new action."
        case .inspectObservation: message = "Inspect the attached observation before deciding on a new action; queue completion is not device confirmation."
        case .reconnectAndObserve: message = "Finish closing this owned session and inspect its cleanup facts, then explicitly connect and observe. Reconnecting does not confirm an earlier release."
        case .checkMediaAndObserve: message = "Check status without input. If media becomes healthy, observe again; if it stays unhealthy, close this owned session before explicitly reconnecting and observing."
        case .resolveError: message = "Resolve the reported service, device or protocol prerequisite, close this owned session, then explicitly reconnect and observe. Reconnecting alone may not fix the cause."
        case .checkSession: message = "Inspect the original session and its cleanup facts; the host may still be running. Do not start a replacement workflow or repeat the action automatically."
        }
        return ["nextAction": rawValue, "requiresReconnect": self == .reconnectAndObserve || self == .resolveError,
                "automaticReplayAllowed": false, "message": message]
    }

    // Called only for native responses, after any associated capture. Never changes
    // execution outcome, release facts, or the original error code.
    static func enrich(_ response: inout [String: Any], control: [String: Any]?) {
        var facts = response["result"] as? [String: Any] ?? [:]
        // A pre-dispatch failure may already carry the exact control snapshot that
        // rejected it. Do not overwrite it if a later media sample has recovered.
        let effectiveControl = facts["controlAvailable"] != nil ? facts : control
        for key in ["controlAvailable", "controlErrorCode", "controlError", "sessionClosing", "hidState"] {
            if facts[key] == nil, let value = effectiveControl?[key] { facts[key] = value }
        }
        let code = (response["error"] as? [String: Any])?["code"] as? String
        let step: [String: Any]
        if code == "session_unavailable" { step = NativeRecovery.checkSession.result }
        else if code == "session_closed" { step = NativeRecovery.reconnectAndObserve.result }
        else if let recovery = effectiveControl?["recovery"] as? [String: Any], effectiveControl?["controlAvailable"] as? Bool == false {
            step = recovery
        } else if code == "native_media_unhealthy" { step = NativeRecovery.checkMediaAndObserve.result }
        else if response["outcome"] as? String == "unknown" || response["requiresObservation"] as? Bool == true
                    || (response["observation"] as? [String: Any])?["ok"] as? Bool == true {
            step = (response["observation"] as? [String: Any])?["ok"] as? Bool == true
                ? NativeRecovery.inspectObservation.result : NativeRecovery.observe.result
        } else if ["device_locked", "capture_unavailable", "capture_context_changed", "invalid_image", "stale_reference", "stale_observation"].contains(code ?? "") {
            step = NativeRecovery.observe.result
        } else { step = NativeRecovery.none.result }
        facts["recovery"] = step
        response["result"] = facts
    }
}

struct NativeControlStatus {
    let code: String?
    let message: String?
    let recovery: NativeRecovery
    var available: Bool { code == nil }
    var result: [String: Any] {
        ["controlAvailable": available, "controlErrorCode": code as Any? ?? NSNull(),
         "controlError": message as Any? ?? NSNull(), "recovery": recovery.result]
    }

    static func resolve(hid: NativeHIDAdapter.State?, media: [String: Any], closing: Bool,
                        startupCode: String?, startupError: String?) -> Self {
        // Preserve irreversible input uncertainty even if media also stops or cancellation follows.
        if hid == .releaseUncertain { return Self(code: "native_release_uncertain", message: "Touch release was not confirmed by the local send barrier; device delivery remains unknown.", recovery: .reconnectAndObserve) }
        if hid == .inputUncertain { return Self(code: "native_input_uncertain", message: "An input failed after a send attempt; this HID session cannot accept more input.", recovery: .reconnectAndObserve) }
        if closing || hid == .cancelled { return Self(code: "native_session_closing", message: "The native session is closing; wait for its cleanup facts.", recovery: .reconnectAndObserve) }
        if let startupError { return Self(code: startupCode ?? "native_control_unavailable", message: startupError, recovery: .resolveError) }
        guard let hid, hid != .unprepared else { return Self(code: "native_hid_unavailable", message: "No negotiated HID surface is available.", recovery: .resolveError) }
        if hid == .contactActive { return Self(code: "native_contact_active", message: "A contact is still active; wait for the original action and inspect the session.", recovery: .checkSession) }
        guard media["healthy"] as? Bool == true else {
            return Self(code: "native_media_unhealthy", message: media["error"] as? String ?? "Media has no recent healthy RTP/RTCP flow.", recovery: .checkMediaAndObserve)
        }
        return Self(code: nil, message: nil, recovery: .none)
    }
}
