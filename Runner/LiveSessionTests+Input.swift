import Network
import XCTest
import Darwin

extension LiveSessionTests {

    @MainActor
    func perform(_ command: [String: Any]) throws -> [String: Any] {
        guard !inputSessionUncertain else {
            throw CommandError(
                "input_session_uncertain",
                message: "Close this session after unconfirmed event synthesis; do not replay")
        }
        guard let kind = command["kind"] as? String,
            ["tap", "double-tap", "long-press", "pinch", "swipe", "type", "press", "home"].contains(kind),
            let expected = command["target"] as? [String: Any],
            let scope = expected["scope"] as? String
        else {
            throw CommandError("invalid_action")
        }
        commandReferences = observedReferences.take()
        let mode = command["mode"] as? String
        let text = command["text"] as? String
        let pressKey = (command["key"] as? String).flatMap(RunnerPressKey.init(rawValue:))
        try validateInput(kind: kind, pressKey: pressKey, text: text, mode: mode)
        guard expected["bundleId"] as? String == currentBundleID else {
            throw CommandError("app_changed", requiresObservation: true)
        }
        let (app, root) = try actionRoot(scope: scope)
        if kind == "home" { return try performHome(command, app: app, root: root) }
        if ["tap", "double-tap", "long-press", "pinch", "swipe"].contains(kind) {
            return try performGesture(command, kind: kind, app: app, root: root)
        }
        let (target, liveSnapshot) = try actionTarget(expected, root: root)
        try validateTextTarget(target, kind: kind)
        if ["type", "press"].contains(kind) {
            postInputContext = screenContext(app: app, root: root)
        }
        switch kind {
        case "type":
            try typeText(text, mode: mode, target: target, snapshot: liveSnapshot, expected: expected)
        case "press": return try press(pressKey, target: target, app: app, root: root)
        default: break
        }
        return ["kind": kind]
    }

    private func validateInput(kind: String, pressKey: RunnerPressKey?, text: String?, mode: String?) throws {
        if kind == "press", pressKey == nil { throw CommandError("invalid_key") }
        if kind == "type" { try validateText(text, mode: mode) }
    }

    @MainActor
    private func validateTextTarget(_ target: XCUIElement, kind: String) throws {
        if ["type", "press"].contains(kind),
            ![XCUIElement.ElementType.textField, .secureTextField, .textView, .searchField].contains(
                target.elementType) {
            throw CommandError("not_text_input")
        }
    }

    private func validateText(_ text: String?, mode: String?) throws {
        guard ["insert", "replace", "append"].contains(mode ?? ""), let text, text.utf8.count <= 4096,
            mode == "replace" || !text.isEmpty,
            text.unicodeScalars.allSatisfy({
                let value = $0.value
                return value == 10
                    || (value >= 32 && value != 127 && value != 133 && value != 0x2028 && value != 0x2029
                        && !(0xF700...0xF8FF).contains(value))
            })
        else { throw CommandError("invalid_text") }
    }

    @MainActor
    private func actionRoot(scope: String) throws -> (XCUIApplication, XCUIElement) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let systemAlerts = springboard.alerts
        let app: XCUIApplication
        let root: XCUIElement
        if scope == "systemAlert" {
            guard systemAlerts.count == 1 else {
                throw CommandError("system_alert_changed", requiresObservation: true)
            }
            app = springboard; root = systemAlerts.firstMatch
        } else {
            guard let currentApp, currentApp.state == .runningForeground, systemAlerts.count == 0 else {
                throw CommandError("app_context_changed", requiresObservation: true)
            }
            app = currentApp
            let alerts = app.alerts
            if scope == "appAlert", alerts.count == 1 {
                root = alerts.firstMatch
            } else if scope == "app", alerts.count == 0 {
                root = app
            } else {
                throw CommandError("app_alert_changed", requiresObservation: true)
            }
        }
        return (app, root)
    }

    @MainActor
    private func performHome(_ command: [String: Any], app: XCUIApplication, root: XCUIElement) throws
        -> [String: Any] {
        guard let raw = command["screenGuard"] as? [String: Any],
            let screenGuard = try? JSONDecoder().decode(
                ScreenGuard.self, from: JSONSerialization.data(withJSONObject: raw))
        else {
            throw CommandError("invalid_screen_guard")
        }
        let context = screenContext(app: app, root: root)
        guard screenGuard.context.matches(context) else {
            throw CommandError("screen_context_changed", requiresObservation: true)
        }
        let screenshot = XCUIScreen.main.screenshot()
        let check = try screenGuard.check(png: screenshot.pngRepresentation, context: context)
        screenGuardResult = check.result
        screenGuardResult?["capturedAt"] = Date().timeIntervalSince1970
        guard check.accepted else { throw CommandError("screen_changed", requiresObservation: true) }
        try event { XCUIDevice.shared.press(.home) }
        // The next observation can be screenshot-only; never invent an App
        // or SpringBoard element target from a Home press acknowledgement.
        currentApp = nil; currentBundleID = nil
        return ["kind": "home", "homePressCompleted": true, "homeScreenConfirmed": false]
    }

    @MainActor
    private func actionTarget(
        _ expected: [String: Any], root: XCUIElement, allowingLeafContentChange: Bool = false,
        classifyingGeometry: Bool = false
    ) throws -> (
        XCUIElement, XCUIElementSnapshot
    ) {
        guard let path = expected["path"] as? [[String: Any]] else {
            throw CommandError("invalid_action")
        }
        let target: XCUIElement
        let liveSnapshot: XCUIElementSnapshot
        do {
            (target, liveSnapshot) = try RunnerAXTree.resolve(
                root: root, path: path, snapshot: freshSnapshot, children: { $0.children },
                bind: { root, selected in
                    guard let element = try RunnerAXBinding.bind(
                        snapshot: selected, query: root.descendants(matching: .any)) as? XCUIElement
                    else { throw CommandError("target_binding_unavailable") }
                    return element
                }, sameIdentity: { first, second in
                    try RunnerAXBinding.identity(of: first)
                        .isEqual(RunnerAXBinding.identity(of: second))
                }, matches: { node, step in
                    let identity = try self.commandReferences.identity(for: step["identityToken"] as? String)
                    guard try identity.isEqual(RunnerAXBinding.identity(of: node)) else { return false }
                    let attributes = RunnerAXTree.validationAttributes(
                        step, leafToken: path.last?["identityToken"] as? String,
                        allowingContentChange: allowingLeafContentChange, value: node.value, label: node.label)
                    return self.matches(node, expected: attributes, ignoringGeometry: classifyingGeometry)
                }, geometryMatches: classifyingGeometry ? { self.matchesFrame($0, expected: $1) } : nil)
        } catch let failure as RunnerAXReferences<NSObject>.Failure {
            throw CommandError(failure.rawValue, requiresObservation: true)
        } catch let failure as RunnerAXTree.Failure {
            if classifyingGeometry && failure == .geometryChanged { throw failure }
            throw CommandError(failure.rawValue, requiresObservation: failure != .invalidPath)
        } catch let error as NSError where error.domain == "RunnerAXBinding" {
            throw CommandError("target_binding_unavailable", requiresObservation: true,
                               message: error.localizedDescription)
        }
        guard target.isEnabled else { throw CommandError("target_disabled") }
        guard target.isHittable else { throw CommandError("target_not_hittable") }
        return (target, liveSnapshot)
    }

    @MainActor
    private func preparedText(
        _ input: String?, mode: String?, kind: String,
        target: XCUIElement, snapshot: XCUIElementSnapshot
    ) throws -> String? {
        var text = input
        if kind == "type", mode == "append", let suffix = text {
            do {
                text = try RunnerTextInput.append(
                    suffix, to: snapshot.value,
                    secure: snapshot.elementType == .secureTextField, placeholder: snapshot.placeholderValue)
            } catch let failure as RunnerTextInput.Failure {
                throw CommandError(failure.rawValue, message: failure.message)
            }
        }
        if kind == "type", let text,
            text.unicodeScalars.contains(where: { $0.value == 10 || $0.value == 13 }),
            target.elementType != .textView {
            throw CommandError(
                "multiline_requires_text_view",
                message: "Runner multiline text requires a text_view; use a separate press for Return")
        }
        return text
    }

    @MainActor
    private func typeText(
        _ text: String?, mode: String?, target initialTarget: XCUIElement,
        snapshot: XCUIElementSnapshot, expected: [String: Any]
    ) throws {
        let transaction = RunnerTextTransaction()
        textTransaction = transaction
        var target = initialTarget
        do {
            let final = try transaction.run(
                initial: snapshot, needsFocus: !(try RunnerAXBinding.keyboardFocus(of: target)).boolValue,
                focus: { try self.event { target.tap() } },
                validate: { allowContentChange in
                    let (app, root) = try self.actionRoot(scope: expected["scope"] as? String ?? "")
                    let (current, snapshot) = try self.actionTarget(
                        expected, root: root, allowingLeafContentChange: allowContentChange,
                        classifyingGeometry: true)
                    try self.validateTextTarget(current, kind: "type")
                    guard try RunnerAXBinding.keyboardFocus(of: current).boolValue else {
                        throw CommandError("keyboard_focus_unconfirmed", requiresObservation: true,
                                           message: "Keyboard focus no longer belongs to the selected element")
                    }
                    target = current
                    self.postInputContext = self.screenContext(app: app, root: root)
                    return snapshot
                }, plan: { current in
                    let input = try self.preparedText(
                        text, mode: mode, kind: "type", target: target, snapshot: current) ?? ""
                    let replacing = mode == "replace" || mode == "append"
                    let deletion = replacing ? try RunnerTextInput.replacementInput(
                        "", value: current.value, secure: current.elementType == .secureTextField,
                        placeholder: current.placeholderValue, deleteKey: XCUIKeyboardKey.delete.rawValue) : ""
                    return RunnerTextTransaction.Plan(replacing: replacing, deletion: deletion, insertion: input)
                }, position: {
                    try self.event { target.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: .command) }
                }, sendText: { input in
                    try self.event { target.typeText(input) }
                }, isEmpty: { RunnerTextInput.isCleared($0.value) }, resultMatches: { current, input in
                    input.isEmpty ? RunnerTextInput.isCleared(current.value) : current.value as? String == input
                })
            postInputTextFields = [ScreenRect(final.frame)]
        } catch let failure as RunnerTextInput.Failure {
            throw CommandError(failure.rawValue, requiresObservation: executionStarted, message: failure.message)
        } catch let failure as RunnerAXTree.Failure {
            throw CommandError(failure.rawValue, requiresObservation: true)
        } catch let failure as RunnerTextTransaction.Failure {
            throw CommandError(failure.rawValue, requiresObservation: true,
                               message: "Text result was not confirmed; inspect textExecution and observe without replay")
        }
    }

    @MainActor
    private func press(
        _ pressKey: RunnerPressKey?, target: XCUIElement, app: XCUIApplication,
        root: XCUIElement
    ) throws -> [String: Any] {
        guard let pressKey else { throw CommandError("invalid_key") }
        let key = keyboardKey(pressKey)
        if pressKey == .return || pressKey == .backspace {
            // typeKey(Delete) can return without deleting on iOS. Use the
            // existing text-input path for Delete/Return; no focus tap.
            try event { target.typeText(key.rawValue) }
        } else {
            try event { target.typeKey(key.rawValue, modifierFlags: pressKey == .shiftTab ? .shift : []) }
        }
        postInputTextFields = [ScreenRect(target.frame)]
        if pressKey == .tab || pressKey == .shiftTab {
            let after = screenContext(app: app, root: root)
            postInputContext = after
            postInputTextFields = visibleTextFields(root: root, context: after)
        }
        return ["kind": "press", "key": pressKey.rawValue, "keyModifiers": pressKey.modifiers]
    }

    private func keyboardKey(_ pressKey: RunnerPressKey) -> XCUIKeyboardKey {
        let key: XCUIKeyboardKey
        switch pressKey {
        case .return: key = .return
        case .backspace: key = .delete
        case .left: key = .leftArrow
        case .right: key = .rightArrow
        case .upArrow: key = .upArrow
        case .down: key = .downArrow
        case .tab, .shiftTab: key = .tab
        }
        return key
    }

    func matches(_ node: XCUIElementSnapshot, expected: [String: Any], ignoringGeometry: Bool = false) -> Bool {
        guard expected["type"] as? UInt == node.elementType.rawValue,
            expected["identifier"] as? String == node.identifier, expected["label"] as? String == node.label,
            expected["enabled"] as? Bool == node.isEnabled
        else { return false }
        guard ignoringGeometry || matchesFrame(node, expected: expected) else { return false }
        return NSDictionary(dictionary: ["value": node.value ?? NSNull()]).isEqual(to: [
            "value": expected["value"] ?? NSNull()
        ])
    }

    private func matchesFrame(_ node: XCUIElementSnapshot, expected: [String: Any]) -> Bool {
        guard let frame = expected["frame"] as? [String: Any] else { return false }
        let actual: [String: Double] = [
            "x": node.frame.minX, "y": node.frame.minY, "width": node.frame.width, "height": node.frame.height
        ]
        return actual.allSatisfy({ key, value in
                (frame[key] as? Double).map { $0.isFinite && abs($0 - value) <= 0.5 } == true
            })
    }
}
