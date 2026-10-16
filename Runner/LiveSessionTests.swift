import Network
import XCTest
import Darwin

// These XCTest symbols are runtime capabilities, not a public API or a linked WDA dependency.
private struct XCTestStateTimeout {
    private typealias Getter = @convention(c) () -> Double
    private typealias Setter = @convention(c) (Double) -> Void
    private let get: Getter
    private let set: Setter

    init?() {
        let symbols = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let getter = dlsym(symbols, "_XCTApplicationStateTimeout"),
              let setter = dlsym(symbols, "_XCTSetApplicationStateTimeout") else { return nil }
        get = unsafeBitCast(getter, to: Getter.self)
        set = unsafeBitCast(setter, to: Setter.self)
    }

    // All callers are synchronous on the Runner's main actor; always restore XCTest's setting.
    func perform(_ body: () throws -> Void) rethrows {
        let previous = get()
        set(1)
        defer { set(previous) }
        try body()
    }
}

private struct CommandError: Error, CustomStringConvertible {
    let code: String
    let description: String
    let requiresObservation: Bool
    init(_ code: String, requiresObservation: Bool = false, message: String? = nil) {
        self.code = code
        self.description = message ?? code
        self.requiresObservation = requiresObservation
    }
}

private final class CommandServer {
    struct Request {
        let body: [String: Any]
        let connection: NWConnection
    }

    let requests: AsyncStream<Request>
    private let continuation: AsyncStream<Request>.Continuation
    private let listener: NWListener
    private let queue = DispatchQueue(label: "iphone-use.commands")
    private var connections: [NWConnection] = []

    init() throws {
        var sink: AsyncStream<Request>.Continuation!
        requests = AsyncStream { sink = $0 }
        continuation = sink
        let parameters = NWParameters.tcp
        let host = ProcessInfo.processInfo.environment["IPHONE_USE_LISTEN_HOST"] ?? "127.0.0.1"
        guard host == "127.0.0.1" || (IPv6Address(host) != nil && host != "::") else {
            throw CommandError("invalid_listen_address")
        }
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: 47821)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { print("IPHONE_USE_LIVE_READY host=\(host) port=47821") }
            if case .failed(let error) = state {
                print("IPHONE_USE_LISTENER_FAILED \(error)")
                self?.continuation.finish()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connections.append(connection)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                if case .cancelled = state { self?.connections.removeAll { $0 === connection } }
            }
            connection.start(queue: queue)
            receive(connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            buffer.append(data ?? Data())
            guard buffer.count <= 65536, error == nil else { connection.cancel(); return }
            if let newline = buffer.firstIndex(of: 10) {
                guard let body = (try? JSONSerialization.jsonObject(with: buffer[..<newline])) as? [String: Any] else {
                    connection.cancel()
                    return
                }
                continuation.yield(Request(body: body, connection: connection))
            } else if done { connection.cancel() }
            else { receive(connection, buffer: buffer) }
        }
    }

    func reply(_ body: [String: Any], to request: Request) async throws {
        var data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        data.append(10)
        await withCheckedContinuation { (sent: CheckedContinuation<Void, Never>) in
            request.connection.send(content: data, completion: .contentProcessed { _ in
                request.connection.cancel()
                sent.resume()
            })
        }
    }

    func stop() {
        listener.cancel()
        continuation.finish()
        queue.async { [self] in connections.forEach { $0.cancel() } }
    }
}

final class LiveSessionTests: XCTestCase {
    private var currentApp: XCUIApplication?
    private var currentBundleID: String?
    private var commandIssues: [String] = []
    private var handlingCommand = false
    private var executionStarted = false
    private var inputCompleted = false
    private var inputSessionUncertain = false
    private var lifecycleFacts: [String: Any]?
    private let stateTimeout = XCTestStateTimeout()
    private var postInputTextFields: [ScreenRect] = []
    private var postInputContext: ScreenContext?
    private var frameStability: FrameStability?
    private var actionFrame: (png: Data, capturedAt: Double, fingerprint: FrameFingerprint)?
    private var screenGuardResult: [String: Any]?

    override func record(_ issue: XCTIssue) {
        if handlingCommand { commandIssues.append(issue.compactDescription) }
        else { super.record(issue) }
    }

    @MainActor
    func testCommandSession() async throws {
        RunnerStartupGuard.finish()
        guard let token = ProcessInfo.processInfo.environment["IPHONE_USE_SESSION_TOKEN"], token.count >= 32 else {
            throw XCTSkip("Start through iphone-use connect to enable the command session", file: #fileID)
        }
        continueAfterFailure = true
        let server = try CommandServer()
        let sessionID = UUID().uuidString
        let started = ProcessInfo.processInfo.systemUptime
        var sequence = 0
        var didShutdown = false
        let hostManaged = ProcessInfo.processInfo.environment["IPHONE_USE_HOST_MANAGED"] == "1"
        let expiry: Task<Void, Never>? = hostManaged ? nil : Task {
            try? await Task.sleep(nanoseconds: 900_000_000_000)
            if !Task.isCancelled { server.stop() }
        }
        defer { expiry?.cancel(); server.stop() }

        for await request in server.requests {
            sequence += 1
            commandIssues = []
            handlingCommand = true
            lifecycleFacts = nil
            executionStarted = false
            inputCompleted = false
            postInputTextFields = []
            postInputContext = nil
            frameStability = nil
            actionFrame = nil
            screenGuardResult = nil
            let began = ProcessInfo.processInfo.systemUptime
            let command = request.body
            var response: [String: Any] = [
                "id": command["id"] ?? NSNull(), "sessionId": sessionID,
                "runnerPid": ProcessInfo.processInfo.processIdentifier, "sequence": sequence,
                "uptimeMs": (began - started) * 1000
            ]
            var stopping = false
            do {
                guard command["token"] as? String == token else { throw CommandError("unauthorized") }
                response["result"] = try await execute(command)
                try checkIssues()
                response["ok"] = true
                stopping = command["op"] as? String == "shutdown"
            } catch {
                response["ok"] = false
                response["error"] = String(describing: error)
                response["errorCode"] = (error as? CommandError)?.code ?? "xctest_error"
                response["requiresObservation"] = (error as? CommandError)?.requiresObservation ?? true
            }
            handlingCommand = false
            if ["launch", "app-lifecycle"].contains(command["op"] as? String ?? "") {
                if let lifecycleFacts { response["result"] = lifecycleFacts }
                response["execution"] = ["started": executionStarted, "completed": response["ok"] as? Bool == true]
            }
            if command["op"] as? String == "act" {
                response["execution"] = ["started": executionStarted, "inputCompleted": inputCompleted,
                                         "completed": response["ok"] as? Bool == true]
                response["stability"] = frameStability?.result
                if response["ok"] as? Bool == false, let reference = frameStability?.comparisonReferencePNG {
                    response["stabilityReferenceBase64"] = reference.base64EncodedString()
                }
                response["screenGuard"] = screenGuardResult
                if let frame = actionFrame {
                    response["frame"] = ["screenshotBase64": frame.png.base64EncodedString(),
                        "capturedAt": frame.capturedAt, "hash": frame.fingerprint.hash,
                        "width": frame.fingerprint.width, "height": frame.fingerprint.height]
                }
            }
            response["runnerMs"] = (ProcessInfo.processInfo.systemUptime - began) * 1000
            try await server.reply(response, to: request)
            print("IPHONE_USE_COMMAND id=\(command["id"] ?? "missing") sequence=\(sequence) op=\(command["op"] ?? "missing") ok=\(response["ok"] ?? false) runnerMs=\(response["runnerMs"] ?? 0) beganUptime=\(began) repliedUptime=\(ProcessInfo.processInfo.systemUptime)")
            if stopping { didShutdown = true; break }
        }
        XCTAssertTrue(didShutdown, "Session ended without an explicit shutdown command", file: #fileID)
    }

    @MainActor
    private func execute(_ command: [String: Any]) async throws -> [String: Any] {
        let op = command["op"] as? String ?? ""
        if op == "ping" {
            let hostManaged = ProcessInfo.processInfo.environment["IPHONE_USE_HOST_MANAGED"] == "1"
            return ["protocol": "agentsoma-spike-jsonl-v1", "lifecycleOwner": hostManaged ? "host" : "spike",
                    "lifetimeLimitSeconds": hostManaged ? NSNull() : 900, "observationVersion": 2,
                    "actionVersion": 9, "launchVersion": 2, "startupGuard": RunnerStartupGuard.facts(), "frameStabilityVersion": 2, "screenGuardVersion": 1, "previewGeometryVersion": 2,
                    "applicationStateTimeoutSupported": stateTimeout != nil]
        }
        if op == "shutdown" { return ["stopped": true] }
        if op == "preview-geometry" {
            // Independent of CoreDevice's display/screenshot cache. No AX walk,
            // PNG encoding, input, or change to the selected application.
            let image = XCUIScreen.main.screenshot().image
            guard let pixels = image.cgImage else { throw CommandError("preview_geometry_unavailable") }
            let orientation: Int
            switch image.imageOrientation {
            case .up: orientation = 1
            case .down: orientation = 3
            case .right: orientation = 6
            case .left: orientation = 8
            default: throw CommandError("preview_geometry_unavailable")
            }
            return ["width": pixels.width, "height": pixels.height, "orientation": orientation]
        }
        if op == "launch" {
            let bundle = command["bundleId"] as? String ?? ""
            guard bundle.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,254}\\z", options: .regularExpression) != nil else {
                throw CommandError("invalid_bundle_id")
            }
            let app = XCUIApplication(bundleIdentifier: bundle)
            let state = app.state
            try event { if state == .notRunning { app.launch() } else { app.activate() } }
            guard app.state == .runningForeground else { throw CommandError("app_not_foreground") }
            currentApp = app
            currentBundleID = bundle
            return ["bundleId": bundle, "appState": app.state.rawValue]
        }
        if op == "app-lifecycle" { return try appLifecycle(command) }
        if op == "observe" {
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let alerts = springboard.alerts
            let count = alerts.count
            if count == 1 {
                return observe(springboard, root: alerts.firstMatch, scope: "systemAlert")
            }
            if count == 0, let app = currentApp, app.state == .runningForeground {
                let localAlerts = app.alerts
                if localAlerts.count == 1 { return observe(app, root: localAlerts.firstMatch, scope: "appAlert") }
                if localAlerts.count == 0 { return observe(app, root: app, scope: "app") }
                return observe(nil, root: nil, scope: "unknown", error: "multiple_app_alerts")
            }
            return observe(nil, root: nil, scope: "unknown",
                           error: count > 1 ? "multiple_system_alerts" : "foreground_app_unknown")
        }
        guard op == "act" else { throw CommandError("unknown_operation") }
        let result = try perform(command)
        inputCompleted = true
        // Home is acknowledged system navigation. Its destination can contain
        // continuously animated icons; page readiness is left to observation.
        if command["kind"] as? String == "home" { return result }
        try await waitForStableFrame()
        return result
    }

    @MainActor
    private func appLifecycle(_ command: [String: Any]) throws -> [String: Any] {
        guard !inputSessionUncertain else { throw CommandError("input_session_uncertain") }
        guard let bundle = command["bundleId"] as? String,
              bundle.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,254}\\z", options: .regularExpression) != nil,
              let relaunch = command["relaunch"] as? Bool else { throw CommandError("invalid_app_lifecycle") }
        guard bundle != "com.apple.springboard", bundle != Bundle.main.bundleIdentifier,
              bundle != Bundle(for: LiveSessionTests.self).bundleIdentifier else { throw CommandError("protected_app_target") }
        let app = XCUIApplication(bundleIdentifier: bundle)
        let before = app.state
        guard before != .unknown else { throw CommandError("app_state_unknown", requiresObservation: true) }
        lifecycleFacts = ["bundleId": bundle, "operation": relaunch ? "relaunch" : "terminate",
            "alreadyStopped": before == .notRunning, "appStateBefore": before.rawValue,
            "terminationRequested": false, "terminationAcknowledged": false, "stoppedConfirmed": false,
            "launchRequested": false, "launchAcknowledged": false, "foregroundConfirmed": false,
            "automaticReplayAllowed": false, "pageReadyConfirmed": false]
        try Task.checkCancellation()
        if before != .notRunning {
            lifecycleFacts?["terminationRequested"] = true
            try event { app.terminate() }
            lifecycleFacts?["terminationAcknowledged"] = true
        }
        guard app.wait(for: .notRunning, timeout: 5) else { throw CommandError("app_stop_unconfirmed", requiresObservation: true) }
        try checkIssues()
        lifecycleFacts?["stoppedConfirmed"] = true
        lifecycleFacts?["appState"] = app.state.rawValue
        if currentBundleID == bundle { currentApp = nil; currentBundleID = nil }
        if relaunch {
            try Task.checkCancellation()
            guard app.state == .notRunning else { throw CommandError("app_restarted_externally", requiresObservation: true) }
            lifecycleFacts?["launchRequested"] = true
            try event { app.launch() }
            lifecycleFacts?["launchAcknowledged"] = true
            guard app.wait(for: .runningForeground, timeout: 5) else { throw CommandError("app_not_foreground", requiresObservation: true) }
            try checkIssues()
            currentApp = app; currentBundleID = bundle
            lifecycleFacts?["foregroundConfirmed"] = true
            lifecycleFacts?["appState"] = app.state.rawValue
        }
        return lifecycleFacts!
    }

    private func checkIssues() throws {
        if !commandIssues.isEmpty { throw CommandError("xctest_error", message: commandIssues.joined(separator: "\n")) }
    }

    @MainActor
    private func event(_ body: () -> Void) throws {
        try checkIssues()
        guard let stateTimeout else { throw CommandError("unsupported_xctest_runtime") }
        executionStarted = true // Before entering any API that can send input, including focus/select-all.
        let began = ProcessInfo.processInfo.systemUptime
        // Idle may exceed this short budget during normal deceleration. Avoid synchronous
        // timeout diagnostics; the caller still checks XCTest errors and frame stability.
        XCTestDiagnostics.withoutAutomaticSpindump { stateTimeout.perform(body) }
        print("IPHONE_USE_INPUT beganUptime=\(began) finishedUptime=\(ProcessInfo.processInfo.systemUptime)")
        try checkIssues()       // Never continue a multi-primitive input after an XCTest failure.
    }

    @MainActor
    private func waitForStableFrame() async throws {
        var stability = FrameStability(startedAt: ProcessInfo.processInfo.systemUptime,
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
            stability.record(frame: fingerprint, png: png, capturedAt: captureFinished,
                             processedAt: ProcessInfo.processInfo.systemUptime)
            frameStability = stability
            actionFrame = (png, capturedAt, fingerprint)
            try checkIssues()
            if stability.stable || stability.observationReady { return }
            let now = ProcessInfo.processInfo.systemUptime
            let delay = min(max(0, FrameStability.sampleInterval - (now - began)), stability.remaining(at: now))
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
        throw CommandError("post_action_capture_timeout", requiresObservation: true,
                           message: "Input completed but insufficient post-action frames were captured; do not replay the action")
    }

    @MainActor
    private func perform(_ command: [String: Any]) throws -> [String: Any] {
        guard !inputSessionUncertain else { throw CommandError("input_session_uncertain", message: "Close this session after unconfirmed event synthesis; do not replay") }
        guard let kind = command["kind"] as? String, ["tap", "double-tap", "long-press", "pinch", "swipe", "type", "press", "home"].contains(kind),
              let expected = command["target"] as? [String: Any],
              let scope = expected["scope"] as? String else {
            throw CommandError("invalid_action")
        }
        let mode = command["mode"] as? String
        var text = command["text"] as? String
        let pressKey = (command["key"] as? String).flatMap(RunnerPressKey.init(rawValue:))
        if kind == "press", pressKey == nil { throw CommandError("invalid_key") }
        if kind == "type" {
            guard ["insert", "replace", "append"].contains(mode ?? ""), let text, text.utf8.count <= 4096,
                  mode == "replace" || !text.isEmpty,
                  text.unicodeScalars.allSatisfy({
                      let v = $0.value
                      return v == 10 || (v >= 32 && v != 127 && v != 133 && v != 0x2028 && v != 0x2029 && !(0xF700...0xF8FF).contains(v))
                  }) else { throw CommandError("invalid_text") }
        }
        guard expected["bundleId"] as? String == currentBundleID else { throw CommandError("app_changed", requiresObservation: true) }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let systemAlerts = springboard.alerts
        let app: XCUIApplication
        let root: XCUIElement
        if scope == "systemAlert" {
            guard systemAlerts.count == 1 else { throw CommandError("system_alert_changed", requiresObservation: true) }
            app = springboard; root = systemAlerts.firstMatch
        } else {
            guard let currentApp, currentApp.state == .runningForeground, systemAlerts.count == 0 else {
                throw CommandError("app_context_changed", requiresObservation: true)
            }
            app = currentApp
            let alerts = app.alerts
            if scope == "appAlert", alerts.count == 1 { root = alerts.firstMatch }
            else if scope == "app", alerts.count == 0 { root = app }
            else { throw CommandError("app_alert_changed", requiresObservation: true) }
        }
        if kind == "home" {
            guard let raw = command["screenGuard"] as? [String: Any],
                  let screenGuard = try? JSONDecoder().decode(ScreenGuard.self, from: JSONSerialization.data(withJSONObject: raw)) else {
                throw CommandError("invalid_screen_guard")
            }
            let context = screenContext(app: app, root: root)
            guard screenGuard.context.matches(context) else { throw CommandError("screen_context_changed", requiresObservation: true) }
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
        if ["tap", "double-tap", "long-press", "pinch", "swipe"].contains(kind) { return try performGesture(command, kind: kind, app: app, root: root) }
        guard let path = expected["path"] as? [[String: Any]], !path.isEmpty, path.count <= 200 else { throw CommandError("invalid_action") }
        var snapshot = try root.snapshot()
        for (index, expectedNode) in path.enumerated() {
            if index > 0 {
                guard let child = expectedNode["childIndex"] as? Int, snapshot.children.indices.contains(child) else {
                    throw CommandError("target_path_changed", requiresObservation: true)
                }
                snapshot = snapshot.children[child]
            }
            guard matches(snapshot, expected: expectedNode) else { throw CommandError("target_changed", requiresObservation: true) }
        }
        let target: XCUIElement
        if path.count == 1 { target = root }
        else {
            let predicate = NSPredicate(format: "identifier == %@ AND label == %@", snapshot.identifier, snapshot.label)
            let matches = root.descendants(matching: snapshot.elementType).matching(predicate)
            let count = matches.count
            guard count == 1 else { throw CommandError(count == 0 ? "target_missing" : "ambiguous_target", requiresObservation: count == 0) }
            target = matches.firstMatch
        }
        let liveSnapshot = try target.snapshot()
        guard matches(liveSnapshot, expected: path.last!) else { throw CommandError("target_changed", requiresObservation: true) }
        guard target.isEnabled else { throw CommandError("target_disabled") }
        guard target.isHittable else { throw CommandError("target_not_hittable") }
        if ["type", "press"].contains(kind), ![XCUIElement.ElementType.textField, .secureTextField, .textView, .searchField].contains(target.elementType) {
            throw CommandError("not_text_input")
        }
        if kind == "type", mode == "append", let suffix = text {
            do { text = try RunnerTextInput.append(suffix, to: liveSnapshot.value,
                                                  secure: liveSnapshot.elementType == .secureTextField, placeholder: liveSnapshot.placeholderValue) }
            catch let failure as RunnerTextInput.Failure { throw CommandError(failure.rawValue, message: failure.message) }
        }
        if kind == "type", let text, text.unicodeScalars.contains(where: { $0.value == 10 || $0.value == 13 }), target.elementType != .textView {
            throw CommandError("multiline_requires_text_view", message: "Runner multiline text requires a text_view; use a separate press for Return")
        }
        if ["type", "press"].contains(kind) {
            postInputContext = screenContext(app: app, root: root)
        }
        switch kind {
        case "type":
            if mode == "replace" || mode == "append" {
                try event { target.tap() }
                try event { target.typeKey("a", modifierFlags: .command) }
                if text?.isEmpty == true { try event { target.typeText(XCUIKeyboardKey.delete.rawValue) } }
            }
            if let text, !text.isEmpty { try event { target.typeText(text) } }
        case "press":
            guard let pressKey else { throw CommandError("invalid_key") }
            let key: XCUIKeyboardKey
            switch pressKey {
            case .return: key = .return
            case .backspace: key = .delete
            case .left: key = .leftArrow
            case .right: key = .rightArrow
            case .up: key = .upArrow
            case .down: key = .downArrow
            case .tab, .shiftTab: key = .tab
            }
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
            return ["kind": kind, "key": pressKey.rawValue, "keyModifiers": pressKey.modifiers]
        default: break
        }
        if kind == "type" { postInputTextFields = [ScreenRect(target.frame)] }
        return ["kind": kind]
    }

    @MainActor
    private func screenContext(app: XCUIApplication, root: XCUIElement) -> ScreenContext {
        ScreenContext(screen: ScreenRect(app.frame), scope: ScreenRect(root.frame),
                      orientation: XCUIDevice.shared.orientation.rawValue, keyboardCount: app.keyboards.count)
    }

    @MainActor
    private func performGesture(_ command: [String: Any], kind: String, app: XCUIApplication, root: XCUIElement) throws -> [String: Any] {
        let gesture: CoordinateGesture
        let context: ScreenContext
        let interfaceOrientation = RunnerPinchEvent.interfaceOrientation(for: app)
        do {
            guard let raw = command["gesture"] as? [String: Any] else { throw ScreenGuard.Failure.invalidGuard }
            gesture = try JSONDecoder().decode(CoordinateGesture.self, from: JSONSerialization.data(withJSONObject: raw))
            try gesture.validate(kind: kind)
            context = screenContext(app: app, root: root)
            guard gesture.screenGuard.context.matches(context), context.scope.cgRect.contains(gesture.start),
                  gesture.end.map({ context.scope.cgRect.contains($0) }) ?? true else { throw ScreenGuard.Failure.contextChanged }
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
            throw CommandError(code, requiresObservation: true, message: "Screen guard could not validate the old observation; observe again")
        }
        guard screenGuardResult?["accepted"] as? Bool == true else {
            throw CommandError("screen_changed", requiresObservation: true,
                               message: "Screen or protected region changed beyond its threshold; observe again before choosing an action")
        }
        guard (1...4).contains(interfaceOrientation), RunnerPinchEvent.interfaceOrientation(for: app) == interfaceOrientation else {
            throw CommandError("gesture_orientation_unavailable", requiresObservation: true)
        }
        func nativePoint(_ point: CGPoint) throws -> CGPoint {
            try RunnerCoordinateMapping.point(point, screen: context.screen, interfaceOrientation: interfaceOrientation)
        }
        func coordinate(_ point: CGPoint) -> XCUICoordinate {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x - context.screen.x, dy: point.y - context.screen.y))
        }
        let start = coordinate(gesture.start)
        if kind == "long-press" {
            guard let duration = command["duration"] as? Double, duration.isFinite, (0.5...5).contains(duration) else {
                throw CommandError("invalid_press_duration")
            }
            try event { start.press(forDuration: duration) }
            return ["kind": kind, "coordinateSpace": "screen_points", "x": gesture.start.x, "y": gesture.start.y, "duration": duration]
        }
        if kind == "double-tap" {
            try event { start.doubleTap() }
            return ["kind": kind, "coordinateSpace": "screen_points", "x": gesture.start.x, "y": gesture.start.y, "tapCount": 2]
        }
        if let pinch = gesture.pinch {
            // Tag the record with the App's interface orientation, but express
            // its paths in native portrait points. Physical face-up is unrelated.
            let orientation = interfaceOrientation
            let from = try pinch.points(center: gesture.start, ending: false).map(nativePoint)
            let to = try pinch.points(center: gesture.start, ending: true).map(nativePoint)
            let eventRecord: RunnerPinchEvent
            do {
                let prepared = try RunnerPinchEvent.prepare(left: from[0], right: from[1], endLeft: to[0], endRight: to[1],
                                                                  duration: pinch.duration, orientation: orientation)
                eventRecord = prepared
            } catch { throw CommandError("unsupported_pinch_runtime", message: String(describing: error)) }
            try checkIssues()
            executionStarted = true
            do { try eventRecord.send(timeout: pinch.duration + 5); try checkIssues() }
            catch {
                inputSessionUncertain = true
                throw CommandError("pinch_completion_unknown", requiresObservation: true, message: String(describing: error))
            }
            return ["kind": kind, "coordinateSpace": "screen_points", "x": gesture.start.x, "y": gesture.start.y,
                    "pinch": pinch.result, "interfaceOrientation": orientation]
        }
        if let end = gesture.end {
            guard let motion = gesture.motion else { throw CommandError("invalid_swipe_motion") }
            let destination = coordinate(end)
            try event {
                start.press(forDuration: motion.pressDuration, thenDragTo: destination,
                            withVelocity: XCUIGestureVelocity(rawValue: CGFloat(motion.velocity)),
                            thenHoldForDuration: motion.holdDuration)
            }
            return ["kind": kind, "coordinateSpace": "screen_points", "fromX": gesture.start.x,
                    "fromY": gesture.start.y, "toX": end.x, "toY": end.y, "motion": motion.result]
        }
        try event { start.tap() }
        // A button can focus an editor too. Read one bounded snapshot; never
        // traverse focus or tap an editor merely to discover a caret region.
        let after = screenContext(app: app, root: root)
        let fields = visibleTextFields(root: root, context: after)
        // Tap retains its sole-field policy; only Tab/Shift+Tab may change editors.
        if fields.count == 1 {
            postInputContext = after
            postInputTextFields = fields
        }
        return ["kind": kind, "coordinateSpace": "screen_points", "x": gesture.start.x, "y": gesture.start.y]
    }

    // Pixel-analysis boundaries only, never proof of focus. No AX focus traversal.
    private func visibleTextFields(root: XCUIElement, context: ScreenContext) -> [ScreenRect] {
        guard context.valid, context.keyboardCount == 1, let snapshot = try? root.snapshot() else { return [] }
        var fields: [ScreenRect] = []
        var visited = 0, truncated = false
        func visit(_ node: XCUIElementSnapshot) {
            guard visited < 200 else { truncated = true; return }
            visited += 1
            let frame = ScreenRect(node.frame)
            if [XCUIElement.ElementType.textField, .secureTextField, .textView, .searchField].contains(node.elementType),
               node.isEnabled, frame.valid, context.scope.cgRect.contains(frame.cgRect) {
                fields.append(frame)
            }
            for child in node.children { visit(child) }
        }
        visit(snapshot)
        return !truncated && fields.count <= 8 ? fields : []
    }

    private func matches(_ node: XCUIElementSnapshot, expected: [String: Any]) -> Bool {
        guard expected["type"] as? UInt == node.elementType.rawValue,
              expected["identifier"] as? String == node.identifier, expected["label"] as? String == node.label,
              expected["enabled"] as? Bool == node.isEnabled,
              let frame = expected["frame"] as? [String: Any] else { return false }
        let actual: [String: Double] = ["x": node.frame.minX, "y": node.frame.minY, "width": node.frame.width, "height": node.frame.height]
        guard actual.allSatisfy({ key, value in (frame[key] as? Double).map { $0.isFinite && abs($0 - value) <= 0.5 } == true }) else { return false }
        return NSDictionary(dictionary: ["value": node.value ?? NSNull()]).isEqual(to: ["value": expected["value"] ?? NSNull()])
    }

    @MainActor
    private func observe(_ app: XCUIApplication?, root: XCUIElement?, scope: String, error: String? = nil) -> [String: Any] {
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
            do { visit(try root.snapshot(), parent: nil) }
            catch { axError = String(describing: error) }
        }
        let snapshotFinished = Date().timeIntervalSince1970
        let frame = app?.frame
        var context: Any = NSNull()
        if let app, let root,
           let encoded = try? JSONEncoder().encode(screenContext(app: app, root: root)),
           let object = try? JSONSerialization.jsonObject(with: encoded) { context = object }
        let screenshot = XCUIScreen.main.screenshot()
        return [
            "bundleId": scope == "systemAlert" ? "com.apple.springboard" : (app != nil ? currentBundleID as Any? ?? NSNull() : NSNull()),
            "targetBundleId": currentBundleID as Any? ?? NSNull(), "scope": scope,
            "foregroundBundleId": ["app", "appAlert"].contains(scope) ? currentBundleID as Any? ?? NSNull() : NSNull(),
            "appState": app.map { $0.state.rawValue as Any } ?? NSNull(),
            "screenFrame": frame.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] as Any } ?? NSNull(),
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
