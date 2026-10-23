import Foundation
import CoreGraphics

extension ObservationCache {

    func resolveTarget(for action: DeviceAction) throws -> ObservedTarget {
        let reference = action.reference
        guard let entry = entries.first(where: { $0.id == reference.observation }), currentID == entry.id
        else {
            throw IPhoneUseError("stale_reference", "Observe again before using this reference for an action")
        }
        if action.kind == "home" {
            return try homeTarget(entry.capture)
        }
        if entry.capture.metadata["backend"] as? String == "apple-native" {
            if ["type", "press"].contains(action.kind), action.reference.node == nil {
                return try textTarget(action, entry: entry)
            }
            guard ["tap", "double-tap", "long-press", "pinch", "swipe"].contains(action.kind),
                action.coordinate
            else {
                throw IPhoneUseError(
                    "native_action_unsupported",
                    "Use tap or swipe oN with native screenshot screen-point coordinates")
            }
            return try coordinateTarget(for: action, capture: entry.capture)
        }
        guard let scope = entry.capture.metadata["scope"] as? String,
            ["app", "appAlert", "systemAlert"].contains(scope),
            !entry.capture.nodes.isEmpty
        else { throw IPhoneUseError("target_context_unknown", "Observe a known app or alert before acting") }
        if ["tap", "double-tap", "long-press", "pinch", "swipe"].contains(action.kind) {
            return try coordinateTarget(for: action, capture: entry.capture)
        }
        return try accessibilityTarget(action, entry: entry)
    }

    private func coordinateTarget(for action: DeviceAction, capture: CapturedObservation) throws
        -> ObservedTarget {
        guard let rawContext = capture.metadata["screenContext"] as? [String: Any],
            let context = try? JSONDecoder().decode(ScreenContext.self, from: jsonData(rawContext)),
            context.valid
        else {
            throw ActionFailure(
                code: "target_context_unknown",
                description: "Observe again with a current Runner before using guarded coordinates",
                possiblyExecuted: false, requiresObservation: true)
        }
        let (start, end) = try gesturePoints(action, context: context)
        guard context.scope.cgRect.contains(start), end.map({ context.scope.cgRect.contains($0) }) ?? true
        else {
            throw IPhoneUseError(
                "invalid_screen_point", "Gesture coordinates must stay inside the observed app or alert")
        }
        if let pinch = action.pinchMotion {
            guard
                (pinch.points(center: start, ending: false) + pinch.points(center: start, ending: true))
                    .allSatisfy({ $0.x.isFinite && $0.y.isFinite && context.scope.cgRect.contains($0) })
            else {
                throw IPhoneUseError(
                    "invalid_screen_point", "Both pinch paths must stay inside the observed scope")
            }
        }
        var rects =
            action.pinchMotion?.regions(center: start, screen: context.screen.cgRect)
            ?? CoordinateGesture.actionRegions(start: start, end: end, screen: context.screen.cgRect)
        rects += try action.protectedReferences.map { ScreenRect(try visibleRect($0, context: context)) }
        let guardValue = try gestureGuard(action, capture: capture, context: context, rects: rects)
        let gesture = CoordinateGesture(
            start: start, end: end, screenGuard: guardValue, motion: action.swipeMotion,
            pinch: action.pinchMotion)
        guard gesture.withinMotionBudget else {
            throw IPhoneUseError(
                "swipe_duration_exceeded",
                """
                Estimated swipe motion exceeds 10 seconds; use a shorter distance, faster velocity or shorter holds
                """)
        }
        try gesture.validate(kind: action.kind)
        return ObservedTarget(context: capture.metadata, path: [], gesture: gesture)
    }
    private func homeTarget(_ capture: CapturedObservation) throws -> ObservedTarget {
        guard let raw = capture.metadata["screenContext"] as? [String: Any] else {
            throw ScreenGuard.Failure.invalidGuard
        }
        let context = try JSONDecoder().decode(ScreenContext.self, from: jsonData(raw))
        // System navigation has no local target; protect the whole observed screen.
        var policy = ScreenGuard.Policy(); policy.maxRegionChange = policy.maxScreenChange
        let guardValue = try ScreenGuard(
            png: capture.screenshot, context: context, rects: [context.screen], policy: policy)
        return ObservedTarget(context: capture.metadata, path: [], textGuard: guardValue)
    }

    private func textTarget(_ action: DeviceAction, entry: Entry) throws -> ObservedTarget {
        if action.kind == "type" {
            _ = try NativeTextInput(
                text: validatedValue(action.fields["text"], as: String.self),
                mode: validatedValue(action.fields["mode"], as: String.self),
                method: action.fields["textMethod"] as? String ?? "auto")
        }
        guard let raw = entry.capture.metadata["screenContext"] as? [String: Any] else {
            throw ScreenGuard.Failure.invalidGuard
        }
        let context = try JSONDecoder().decode(ScreenContext.self, from: jsonData(raw))
        let guardValue = try ScreenGuard(
            png: entry.capture.screenshot, context: context, rects: [action.textRegion ?? context.screen],
            policy: .init(), ignoring: action.ignoredScreenRect)
        let fieldGuard = try NativeTextFieldGuard(
            png: entry.capture.screenshot, context: context, field: action.textRegion ?? context.screen)
        let caret = try action.caretRegion.map {
            try NativeBoundCaretGuard(field: fieldGuard, caret: $0, observationID: entry.id)
        }
        return ObservedTarget(
            context: entry.capture.metadata, path: [], textGuard: guardValue, textFieldGuard: fieldGuard,
            textCaretGuard: caret)
    }

    private func accessibilityTarget(_ action: DeviceAction, entry: Entry) throws -> ObservedTarget {
        var index = 0
        if !action.coordinate {
            let node = try resolveCurrent(action.reference)
            if ["type", "press"].contains(action.kind),
                !["text_field", "secure_text_field", "text_view", "search_field"].contains(node.role) {
                throw IPhoneUseError("not_text_input", "The reference must identify a text input")
            }
            if action.kind == "type", var text = action.fields["text"] as? String {
                if action.fields["mode"] as? String == "append" {
                    do {
                        text = try RunnerTextInput.append(
                            text, to: node.attributes["value"], secure: node.role == "secure_text_field")
                    } catch let failure as RunnerTextInput.Failure {
                        throw IPhoneUseError(failure.rawValue, failure.message)
                    }
                }
                if text.unicodeScalars.contains(where: { $0.value == 10 || $0.value == 13 }),
                    node.role != "text_view" {
                    throw IPhoneUseError(
                        "multiline_requires_text_view",
                        "Runner multiline text requires a text_view; use a separate press for Return")
                }
            }
            index = node.index
        }
        var path: [[String: Any]] = []
        while true {
            let node = entry.capture.nodes[index]
            var step = node.attributes
            step.removeValue(forKey: "index"); step.removeValue(forKey: "parent")
            step["childIndex"] =
                node.parent.map { parent in entry.capture.nodes[..<index].filter { $0.parent == parent }.count
                } ?? 0
            path.insert(step, at: 0)
            guard let parent = node.parent else { break }
            index = parent
        }
        return ObservedTarget(context: entry.capture.metadata, path: path)
    }
    private func visibleRect(_ reference: ObservationReference, context: ScreenContext) throws -> CGRect {
        let node = try resolveCurrent(reference)
        guard let raw = node.attributes["frame"] as? [String: Any],
            let rect = try? JSONDecoder().decode(ScreenRect.self, from: jsonData(raw)), rect.valid
        else {
            throw IPhoneUseError("invalid_target_frame", "The captured element has no usable bounds")
        }
        let visible = rect.cgRect.intersection(context.scope.cgRect)
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else {
            throw IPhoneUseError(
                "target_not_visible",
                "The captured element is outside the observed scope; no automatic scrolling")
        }
        return visible
    }

    private func gesturePoints(_ action: DeviceAction, context: ScreenContext) throws -> (CGPoint, CGPoint?) {
        let start: CGPoint
        var end: CGPoint?
        if action.coordinate {
            if ["tap", "double-tap", "long-press", "pinch"].contains(action.kind) {
                start = CGPoint(
                    x: validatedValue(action.fields["x"], as: Double.self),
                    y: validatedValue(action.fields["y"], as: Double.self))
            } else {
                start = CGPoint(
                    x: validatedValue(action.fields["fromX"], as: Double.self),
                    y: validatedValue(action.fields["fromY"], as: Double.self))
                end = CGPoint(
                    x: validatedValue(action.fields["toX"], as: Double.self),
                    y: validatedValue(action.fields["toY"], as: Double.self))
            }
        } else {
            guard try resolveCurrent(action.reference).enabled else {
                throw IPhoneUseError("target_disabled", "The observed element is disabled")
            }
            let rect = try visibleRect(action.reference, context: context)
            if ["tap", "double-tap", "long-press", "pinch"].contains(action.kind) {
                start = CGPoint(x: rect.midX, y: rect.midY)
            } else {
                let direction = validatedValue(action.fields["direction"], as: String.self)
                let vertical = ["up", "down"].contains(direction)
                let low = CGPoint(
                    x: vertical ? rect.midX : rect.minX + rect.width * 0.2,
                    y: vertical ? rect.minY + rect.height * 0.2 : rect.midY)
                let high = CGPoint(
                    x: vertical ? rect.midX : rect.minX + rect.width * 0.8,
                    y: vertical ? rect.minY + rect.height * 0.8 : rect.midY)
                start = ["up", "left"].contains(direction) ? high : low
                end = ["up", "left"].contains(direction) ? low : high
            }
        }
        return (start, end)
    }

    private func gestureGuard(
        _ action: DeviceAction, capture: CapturedObservation,
        context: ScreenContext, rects: [ScreenRect]
    ) throws -> ScreenGuard {
        let guardValue: ScreenGuard
        do {
            guardValue = try ScreenGuard(
                png: capture.screenshot, context: context, rects: rects, policy: action.guardPolicy,
                ignoring: action.ignoredScreenRect, dynamicRects: action.dynamicRects)
        } catch let failure as ScreenGuard.DynamicBaselineFailure {
            throw ActionFailure(
                code: failure.code, description: failure.message,
                possiblyExecuted: false, requiresObservation: true,
                result: ["screenGuardPreparation": failure.diagnostics])
        } catch {
            throw ActionFailure(
                code: (error as? ScreenGuard.Failure)?.rawValue ?? "screen_guard_unavailable",
                description: action.ignoredScreenRect == nil
                    ? "Cannot prepare a screen guard from this observation; observe again"
                    : """
                    Ignored rectangle must be inside this screenshot, cover at most 25%, and not overlap any\
                     protected touch, path or context region
                    """,
                possiblyExecuted: false, requiresObservation: true)
        }
        return guardValue
    }
}
