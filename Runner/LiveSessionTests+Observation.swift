import Network
import XCTest
import Darwin

extension LiveSessionTests {

    @MainActor
    func waitForStableFrame() async throws {
        var stability = FrameStability(
            startedAt: ProcessInfo.processInfo.systemUptime,
            context: postInputContext, textFields: postInputTextFields)
        frameStability = stability
        while stability.remaining(at: ProcessInfo.processInfo.systemUptime) > 0 {
            try Task.checkCancellation()
            let began = ProcessInfo.processInfo.systemUptime
            let screenshot = XCUIScreen.main.screenshot()
            let captureFinished = ProcessInfo.processInfo.systemUptime
            let capturedAt = Date().timeIntervalSince1970
            let png = screenshot.pngRepresentation
            let fingerprint = try FrameFingerprint(png: png)
            stability.record(
                frame: fingerprint, png: png, capturedAt: captureFinished,
                processedAt: ProcessInfo.processInfo.systemUptime)
            frameStability = stability
            actionFrame = ActionFrame(png: png, capturedAt: capturedAt, fingerprint: fingerprint)
            try checkIssues()
            if stability.stable || stability.observationReady { return }
            let now = ProcessInfo.processInfo.systemUptime
            let delay = min(
                max(0, FrameStability.sampleInterval - (now - began)), stability.remaining(at: now))
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
        throw CommandError(
            "post_action_capture_timeout", requiresObservation: true,
            message:
                "Input completed but insufficient post-action frames were captured; do not replay the action")
    }

    // Pixel-analysis boundaries only, never proof of focus. No AX focus traversal.
    func visibleTextFields(root: XCUIElement, context: ScreenContext) -> [ScreenRect] {
        guard context.valid, context.keyboardCount == 1, let snapshot = try? root.snapshot() else {
            return []
        }
        var fields: [ScreenRect] = []
        var visited = 0, truncated = false
        func visit(_ node: XCUIElementSnapshot) {
            guard visited < 200 else { truncated = true; return }
            visited += 1
            let frame = ScreenRect(node.frame)
            if [XCUIElement.ElementType.textField, .secureTextField, .textView, .searchField].contains(
                node.elementType),
                node.isEnabled, frame.valid, context.scope.cgRect.contains(frame.cgRect) {
                fields.append(frame)
            }
            for child in node.children { visit(child) }
        }
        visit(snapshot)
        return !truncated && fields.count <= 8 ? fields : []
    }

    @MainActor
    func observe(
        _ app: XCUIApplication?, root: XCUIElement?, scope: String, error: String? = nil
    ) -> [String: Any] {
        let snapshotTime = Date().timeIntervalSince1970
        var nodes: [[String: Any]] = []
        var truncated = false
        var axError = error
        func visit(_ node: XCUIElementSnapshot, parent: Int?) {
            guard nodes.count < 200 else { truncated = true; return }
            let index = nodes.count
            let frame = node.frame
            nodes.append([
                "index": index, "parent": parent.map { $0 as Any } ?? NSNull(),
                "type": node.elementType.rawValue, "identifier": node.identifier,
                "label": node.label, "value": node.value ?? NSNull(), "enabled": node.isEnabled,
                "frame": ["x": frame.minX, "y": frame.minY, "width": frame.width, "height": frame.height]
            ])
            node.children.forEach { visit($0, parent: index) }
        }
        if let root {
            do { visit(try root.snapshot(), parent: nil) } catch { axError = String(describing: error) }
        }
        let snapshotFinished = Date().timeIntervalSince1970
        let frame = app?.frame
        var context: Any = NSNull()
        if let app, let root,
            let encoded = try? JSONEncoder().encode(screenContext(app: app, root: root)),
            let object = try? JSONSerialization.jsonObject(with: encoded) {
            context = object
        }
        let screenshot = XCUIScreen.main.screenshot()
        return [
            "bundleId": scope == "systemAlert"
                ? "com.apple.springboard" : (app != nil ? currentBundleID as Any? ?? NSNull() : NSNull()),
            "targetBundleId": currentBundleID as Any? ?? NSNull(), "scope": scope,
            "foregroundBundleId": ["app", "appAlert"].contains(scope)
                ? currentBundleID as Any? ?? NSNull() : NSNull(),
            "appState": app.map { $0.state.rawValue as Any } ?? NSNull(),
            "screenFrame": frame.map {
                ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] as Any
            }
                ?? NSNull(),
            "coordinateSpace": "screen_points", "nodes": nodes, "truncated": truncated,
            "screenContext": context,
            "axStatus": nodes.isEmpty ? "unavailable" : "available", "axError": axError as Any? ?? NSNull(),
            "snapshotStartedAt": snapshotTime, "snapshotFinishedAt": snapshotFinished,
            "screenshotCapturedAt": Date().timeIntervalSince1970,
            "screenshotWidth": screenshot.image.size.width * screenshot.image.scale,
            "screenshotHeight": screenshot.image.size.height * screenshot.image.scale,
            "screenshotBase64": screenshot.pngRepresentation.base64EncodedString()
        ]
    }
}
