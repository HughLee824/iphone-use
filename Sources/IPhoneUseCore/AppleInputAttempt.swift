import Foundation
import CoreGraphics
import AppleNativeBridge

// One request on the host's existing device work queue. No asynchronous work is added.
final class AppleInputAttempt {
    let backend: AppleDeviceBackend
    let action: DeviceAction
    let target: ObservedTarget
    let textInput: NativeTextInput?
    let hid: NativeHIDAdapter
    let screenGuard: ScreenGuard
    let rotation: String
    let swipe: NativeSwipePlan?
    let pinch: NativePinchPlan?
    var timing: NativeInputTiming
    var keyboardAction: Bool {
        (action.kind == "type" || action.kind == "press") && action.reference.node == nil
    }
    var homeAction: Bool { action.kind == "home" }
    var pressing: Bool { action.kind == "press" && action.reference.node == nil }
    var captures = 0
    var preInputChecks: [[String: Any]] = []
    var inputBudget: NativeCaptureBudget?

    init(
        backend: AppleDeviceBackend, action: DeviceAction, target: ObservedTarget, textInput: NativeTextInput?
    ) throws {
        self.backend = backend; self.action = action; self.target = target; self.textInput = textInput
        let keyboardAction = (action.kind == "type" || action.kind == "press") && action.reference.node == nil
        let homeAction = action.kind == "home"
        let control = backend.controlStatus(mediaHealth: backend.mediaStatus)
        guard control.available, let hid = backend.hid else {
            throw ActionFailure(
                code: "native_control_unavailable",
                description: control.message ?? "Native control is unavailable",
                possiblyExecuted: false, requiresObservation: false, result: control.result)
        }
        guard target.context["deviceID"] as? String == backend.cli?.device,
            target.context["sessionGeneration"] as? String == backend.generation,
            let captured = target.context["captureStartedUptime"] as? Double,
            let screenGuard = (keyboardAction || homeAction) ? target.textGuard : target.gesture?.screenGuard
        else {
            throw ActionFailure(
                code: "stale_observation", description: "Observe this device/session again before input",
                possiblyExecuted: false, requiresObservation: true)
        }
        let timing = try NativeInputTiming(
            captured: captured, now: ProcessInfo.processInfo.systemUptime,
            policy: keyboardAction ? .keyboard : (homeAction ? .system : .coordinateGesture))
        guard let rotation = target.context["displayRotation"] as? String,
            ["rot0", "rot90", "rot270"].contains(rotation),
            target.context["nativeRotation"] as? String == "rot0"
        else {
            throw IPhoneUseError(
                "native_orientation_unsupported",
                "Native HID requires portrait or landscape on a native-portrait display")
        }
        if let gesture = target.gesture { try gesture.validate(kind: action.kind) }
        let swipe =
            action.kind == "swipe" ? try NativeSwipePlan(gesture: target.gesture!, rotation: rotation) : nil
        let pinch =
            action.kind == "pinch" ? try NativePinchPlan(gesture: target.gesture!, rotation: rotation) : nil
        self.hid = hid; self.screenGuard = screenGuard; self.timing = timing
        self.rotation = rotation; self.swipe = swipe; self.pinch = pinch
    }

    func run(onInputStarted: @escaping () -> Void) throws -> [String: Any] {
        try prepareControls()
        let check = try checkBeforeInput()
        var result = try dispatch(onInputStarted: onInputStarted)
        result["sourceObservationID"] = action.reference.observation
        result["inputTiming"] = timing.result
        result["displayRotation"] = rotation
        result["nativeRotation"] = target.context["nativeRotation"]
        result["screenGuard"] = check.result
        result["preInputCaptures"] = captures
        result["preInputChecks"] = preInputChecks
        if keyboardAction {
            let rect = screenGuard.regions[0].rect
            result["textFieldRect"] = [
                "x": rect.originX, "y": rect.originY, "width": rect.width, "height": rect.height
            ]
        }
        return result
    }

    private func prepareControls() throws {
        if keyboardAction {
            try screenGuard.validate()
            guard screenGuard.regions.map(\.rect) == [action.textRegion ?? screenGuard.context.screen] else {
                throw ScreenGuard.Failure.invalidGuard
            }
            // Discover the built-in keyboard, then capture/guard before any key.
            try hid.prepareKeyboard()
        }
        if homeAction {
            try screenGuard.validate()
            guard screenGuard.regions.map(\.rect) == [screenGuard.context.screen] else {
                throw ScreenGuard.Failure.invalidGuard
            }
            if let buttonError = backend.buttonError {
                throw IPhoneUseError("native_home_unavailable", buttonError)
            }
            if backend.buttonTransport == nil {
                guard let tunnel = backend.tunnel else {
                    throw IPhoneUseError("native_hid_unavailable", "Native tunnel unavailable")
                }
                do {
                    backend.buttonTransport = try AppleServiceTransport(
                        tunnel: tunnel, service: "com.apple.coredevice.hid.indigo")
                } catch {
                    backend.buttonError = String(describing: error)
                    throw error // Preserve the denial; never retry service creation in this session.
                }
            }
        }
    }
    func preflight(stage: String) throws -> ScreenGuard.Check {
        let budget = try timing.captureBudget(now: ProcessInfo.processInfo.systemUptime)
        inputBudget = budget
        let deadline = budget.requestDeadline
        let (value, count) = try NativeInputPreflight.check(
            guard: screenGuard,
            displayID: target.context["displayID"] as? UInt64, displayRotation: rotation,
            captureSource: target.context["captureSource"] as? String,
            deadline: deadline,
            maximumCaptures: 1, fieldGuard: keyboardAction ? target.textFieldGuard : nil,
            caretGuard: keyboardAction ? target.textCaretGuard : nil, budget: budget,
            record: { sample in
                var sample = sample; sample["stage"] = stage
                preInputChecks.append(sample)
            },
            capture: {
                try backend.checkInputAvailability(budget: budget)
                return try backend.capture(budget: budget)
            })
        captures += count
        return value
    }

    private func checkBeforeInput() throws -> ScreenGuard.Check {
        var check: ScreenGuard.Check
        do {
            check = try preflight(
                stage: textInput?.usesPasteboard == true ? "before_clipboard" : "before_input")
            if case .pasteboard(let text) = textInput {
                try stageClipboard(text)
                // A clipboard operation can trigger UI. Recheck against the same
                // source observation after staging; never replace the guard baseline.
                check = try preflight(stage: "after_clipboard")
                try backend.pasteboard!.checkOwnership()
            }
            try backend.cancellation.check()
            try backend.checkInputAvailability(budget: inputBudget)
            try timing.checkBeforeDispatch(now: ProcessInfo.processInfo.systemUptime)
        } catch let failure as ActionFailure {
            var result = failure.result ?? [:]
            result["inputTiming"] = timing.result
            result["preInputChecks"] = preInputChecks
            result["preInputCaptures"] = captures + (result["preInputCaptures"] as? Int ?? 0)
            if let pasteboard = backend.pasteboard { result["pasteboard"] = pasteboard.status }
            throw ActionFailure(
                code: failure.code, description: failure.description,
                possiblyExecuted: failure.possiblyExecuted,
                requiresObservation: failure.requiresObservation, result: result,
                rejectedCapture: failure.rejectedCapture)
        } catch {
            throw preflightFailure(error)
        }
        return check
    }

    private func stageClipboard(_ text: String) throws {
        do {
            if let pasteboardError = backend.pasteboardError {
                throw IPhoneUseError("native_pasteboard_unavailable", pasteboardError)
            }
            if backend.pasteboard == nil {
                guard let tunnel = backend.tunnel else {
                    throw IPhoneUseError("native_pasteboard_unavailable", "Native tunnel is unavailable")
                }
                let transport = try AppleServiceTransport(
                    tunnel: tunnel, service: "com.apple.coredevice.pasteboardservice")
                backend.pasteboardTransport = transport
                backend.pasteboard = NativeTextPasteboard(
                    pasteboardIO: AppleTextPasteboardIO(
                        transport: transport, cancellation: backend.cancellation))
            }
            if backend.pasteboard?.restored == true, let transport = backend.pasteboardTransport {
                backend.pasteboard = NativeTextPasteboard(
                    pasteboardIO: AppleTextPasteboardIO(
                        transport: transport, cancellation: backend.cancellation))
            }
            try backend.cancellation.check()
            try backend.pasteboard!.stage(text, sourceObservationID: action.reference.observation)
        } catch {
            backend.pasteboardError = String(describing: error)
            throw ActionFailure(
                code: "native_pasteboard_unavailable",
                description: "Clipboard preparation failed; no paste shortcut was sent: \(error)",
                possiblyExecuted: false, requiresObservation: true,
                result: [
                    "pasteboard": backend.pasteboard?.status ?? [:],
                    "recovery": NativeRecovery.resolveError.result
                ])
        }
    }

    private func preflightFailure(_ error: Error) -> ActionFailure {
        if let failure = error as? IPhoneUseError,
            ["native_media_busy", "native_media_ownership_unknown", "native_media_unhealthy"].contains(
                failure.code) {
            return ActionFailure(
                code: failure.code, description: failure.description,
                possiblyExecuted: false, requiresObservation: false,
                result: [
                    "controlAvailable": false, "controlErrorCode": failure.code,
                    "controlError": failure.description, "recovery": NativeRecovery.resolveError.result
                ])
        }
        let code =
            (error as? IPhoneUseError)?.code == "input_preflight_timeout"
            ? "input_preflight_timeout" : "stale_observation"
        return ActionFailure(
            code: code, description: "Pre-input capture/guard/clipboard check failed: \(error)",
            possiblyExecuted: false, requiresObservation: true,
            result: [
                "pasteboard": backend.pasteboard?.status ?? [:], "preInputChecks": preInputChecks,
                "inputTiming": timing.result
            ])
    }
}
