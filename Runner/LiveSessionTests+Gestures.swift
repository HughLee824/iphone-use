import Network
import XCTest
import Darwin

extension LiveSessionTests {

    @MainActor
    func screenContext(app: XCUIApplication, root: XCUIElement) -> ScreenContext {
        ScreenContext(
            screen: ScreenRect(app.frame), scope: ScreenRect(root.frame),
            orientation: XCUIDevice.shared.orientation.rawValue, keyboardCount: app.keyboards.count)
    }

    @MainActor
    func performGesture(_ command: [String: Any], kind: String, app: XCUIApplication, root: XCUIElement)
        throws
        -> [String: Any] {
        let interfaceOrientation = RunnerPinchEvent.interfaceOrientation(for: app)
        let (gesture, context) = try validateGesture(command, kind: kind, app: app, root: root)
        guard (1...4).contains(interfaceOrientation),
            RunnerPinchEvent.interfaceOrientation(for: app) == interfaceOrientation
        else {
            throw CommandError("gesture_orientation_unavailable", requiresObservation: true)
        }
        func coordinate(_ point: CGPoint) -> XCUICoordinate {
            app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: point.x - context.screen.originX, dy: point.y - context.screen.originY))
        }
        let start = coordinate(gesture.start)
        if kind == "long-press" {
            return try performLongPress(command, start: start, gesture: gesture, kind: kind)
        }
        if kind == "double-tap" {
            try event { start.doubleTap() }
            return [
                "kind": kind, "coordinateSpace": "screen_points", "x": gesture.start.x, "y": gesture.start.y,
                "tapCount": 2
            ]
        }
        if let pinch = gesture.pinch {
            return try performPinch(
                pinch, gesture: gesture, kind: kind, context: context,
                interfaceOrientation: interfaceOrientation)
        }
        if let end = gesture.end {
            guard let motion = gesture.motion else { throw CommandError("invalid_swipe_motion") }
            let destination = coordinate(end)
            try event {
                start.press(
                    forDuration: motion.pressDuration, thenDragTo: destination,
                    withVelocity: XCUIGestureVelocity(rawValue: CGFloat(motion.velocity)),
                    thenHoldForDuration: motion.holdDuration)
            }
            return [
                "kind": kind, "coordinateSpace": "screen_points", "fromX": gesture.start.x,
                "fromY": gesture.start.y, "toX": end.x, "toY": end.y, "motion": motion.result
            ]
        }
        try event { start.tap() }
        // A button can focus an editor too. Read one bounded snapshot; never
        // traverse focus or tap an editor merely to discover a caret region.
        updateTextContext(app: app, root: root)
        return ["kind": kind, "coordinateSpace": "screen_points", "x": gesture.start.x, "y": gesture.start.y]
    }
    @MainActor
    private func validateGesture(
        _ command: [String: Any], kind: String, app: XCUIApplication,
        root: XCUIElement
    ) throws -> (CoordinateGesture, ScreenContext) {
        let gesture: CoordinateGesture
        let context: ScreenContext
        do {
            guard let raw = command["gesture"] as? [String: Any] else {
                throw ScreenGuard.Failure.invalidGuard
            }
            gesture = try JSONDecoder().decode(
                CoordinateGesture.self, from: JSONSerialization.data(withJSONObject: raw))
            try gesture.validate(kind: kind)
            context = screenContext(app: app, root: root)
            guard gesture.screenGuard.context.matches(context), context.scope.cgRect.contains(gesture.start),
                gesture.end.map({ context.scope.cgRect.contains($0) }) ?? true
            else { throw ScreenGuard.Failure.contextChanged }
            let screenshot = XCUIScreen.main.screenshot()
            let capturedAt = Date().timeIntervalSince1970
            try checkIssues()
            let check = try gesture.screenGuard.check(png: screenshot.pngRepresentation, context: context)
            screenGuardResult = check.result
            screenGuardResult?["capturedAt"] = capturedAt
            screenGuardResult?["regions"] = try gesture.screenGuard.regions.map {
                try JSONSerialization.jsonObject(with: JSONEncoder().encode($0.rect))
            }
        } catch {
            let code = (error as? ScreenGuard.Failure)?.rawValue ?? "screen_guard_unavailable"
            screenGuardResult = ["accepted": false, "reason": code]
            throw CommandError(
                code, requiresObservation: true,
                message: "Screen guard could not validate the old observation; observe again")
        }
        guard screenGuardResult?["accepted"] as? Bool == true else {
            throw CommandError(
                "screen_changed", requiresObservation: true,
                message:
                    "Screen or protected region changed beyond its threshold; observe again before choosing an action"
            )
        }
        return (gesture, context)
    }

    @MainActor
    private func performPinch(
        _ pinch: PinchMotion, gesture: CoordinateGesture, kind: String,
        context: ScreenContext, interfaceOrientation: Int
    ) throws -> [String: Any] {
        func nativePoint(_ point: CGPoint) throws -> CGPoint {
            try RunnerCoordinateMapping.point(
                point, screen: context.screen, interfaceOrientation: interfaceOrientation)
        }
        // Tag the record with the App's interface orientation, but express
        // its paths in native portrait points. Physical face-up is unrelated.
        let orientation = interfaceOrientation
        let from = try pinch.points(center: gesture.start, ending: false).map(nativePoint)
        let destination = try pinch.points(center: gesture.start, ending: true).map(nativePoint)
        let eventRecord: RunnerPinchEvent
        do {
            let prepared = try RunnerPinchEvent.prepare(
                left: from[0], right: from[1], endLeft: destination[0], endRight: destination[1],
                duration: pinch.duration, orientation: orientation)
            eventRecord = prepared
        } catch { throw CommandError("unsupported_pinch_runtime", message: String(describing: error)) }
        try checkIssues()
        publishInputStarted()
        executionStarted = true
        do { try eventRecord.send(timeout: pinch.duration + 5); try checkIssues() } catch {
            inputSessionUncertain = true
            throw CommandError(
                "pinch_completion_unknown", requiresObservation: true, message: String(describing: error))
        }
        return [
            "kind": kind, "coordinateSpace": "screen_points", "x": gesture.start.x, "y": gesture.start.y,
            "pinch": pinch.result, "interfaceOrientation": orientation
        ]
    }
    @MainActor
    private func updateTextContext(app: XCUIApplication, root: XCUIElement) {
        let after = screenContext(app: app, root: root)
        let fields = visibleTextFields(root: root, context: after)
        // Tap retains its sole-field policy; only Tab/Shift+Tab may change editors.
        if fields.count == 1 {
            postInputContext = after
            postInputTextFields = fields
        }
    }

    @MainActor
    private func performLongPress(
        _ command: [String: Any], start: XCUICoordinate, gesture: CoordinateGesture, kind: String
    ) throws -> [String: Any] {
        guard let duration = command["duration"] as? Double, duration.isFinite, (0.5...5).contains(duration)
        else {
            throw CommandError("invalid_press_duration")
        }
        try event { start.press(forDuration: duration) }
        return [
            "kind": kind, "coordinateSpace": "screen_points", "x": gesture.start.x, "y": gesture.start.y,
            "duration": duration
        ]
    }

}
