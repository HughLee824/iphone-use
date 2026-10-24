import Network
import XCTest
import Darwin

extension LiveSessionTests {

    @MainActor
    func execute(_ command: [String: Any]) async throws -> [String: Any] {
        let operation = command["op"] as? String ?? ""
        if operation == "ping" {
            let hostManaged = ProcessInfo.processInfo.environment["IPHONE_USE_HOST_MANAGED"] == "1"
            return [
                "protocol": "iphone-use-spike-jsonl-v1", "lifecycleOwner": hostManaged ? "host" : "spike",
                "lifetimeLimitSeconds": hostManaged ? NSNull() : 900, "observationVersion": 4,
                "actionVersion": 12, "launchVersion": 2, "startupGuard": RunnerStartupGuard.facts(),
                "frameStabilityVersion": 2, "screenGuardVersion": 1, "previewGeometryVersion": 2,
                "inputProgressVersion": 1,
                "applicationStateTimeoutSupported": stateTimeout != nil
            ]
        }
        if operation == "shutdown" { return ["stopped": true] }
        if operation == "preview-geometry" { return try previewGeometryCommand() }
        if operation == "launch" { return try launchCommand(command) }
        if operation == "app-lifecycle" { return try appLifecycle(command) }
        if operation == "observe" { return try observeCurrentCommand() }
        guard operation == "act" else { throw CommandError("unknown_operation") }
        let result = try perform(command)
        inputCompleted = true
        // Home is acknowledged system navigation. Its destination can contain
        // continuously animated icons; page readiness is left to observation.
        if command["kind"] as? String == "home" { return result }
        try await waitForStableFrame()
        return result
    }

    @MainActor
    private func previewGeometryCommand() throws -> [String: Any] {

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

    @MainActor
    private func launchCommand(_ command: [String: Any]) throws -> [String: Any] {

        let bundle = command["bundleId"] as? String ?? ""
        guard bundle.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,254}\\z", options: .regularExpression) != nil
        else {
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

    @MainActor
    private func observeCurrentCommand() throws -> [String: Any] {

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
        return observe(
            nil, root: nil, scope: "unknown",
            error: count > 1 ? "multiple_system_alerts" : "foreground_app_unknown")
    }

    @MainActor
    private func appLifecycle(_ command: [String: Any]) throws -> [String: Any] {
        guard !inputSessionUncertain else { throw CommandError("input_session_uncertain") }
        guard let bundle = command["bundleId"] as? String,
            bundle.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,254}\\z", options: .regularExpression) != nil,
            let relaunch = command["relaunch"] as? Bool
        else { throw CommandError("invalid_app_lifecycle") }
        guard bundle != "com.apple.springboard", bundle != Bundle.main.bundleIdentifier,
            bundle != Bundle(for: LiveSessionTests.self).bundleIdentifier
        else { throw CommandError("protected_app_target") }
        let app = XCUIApplication(bundleIdentifier: bundle)
        let before = app.state
        guard before != .unknown else { throw CommandError("app_state_unknown", requiresObservation: true) }
        lifecycleFacts = [
            "bundleId": bundle, "operation": relaunch ? "relaunch" : "terminate",
            "alreadyStopped": before == .notRunning, "appStateBefore": before.rawValue,
            "terminationRequested": false, "terminationAcknowledged": false, "stoppedConfirmed": false,
            "launchRequested": false, "launchAcknowledged": false, "foregroundConfirmed": false,
            "automaticReplayAllowed": false, "pageReadyConfirmed": false
        ]
        try Task.checkCancellation()
        if before != .notRunning {
            lifecycleFacts?["terminationRequested"] = true
            try event { app.terminate() }
            lifecycleFacts?["terminationAcknowledged"] = true
        }
        guard app.wait(for: .notRunning, timeout: 5) else {
            throw CommandError("app_stop_unconfirmed", requiresObservation: true)
        }
        try checkIssues()
        lifecycleFacts?["stoppedConfirmed"] = true
        lifecycleFacts?["appState"] = app.state.rawValue
        if currentBundleID == bundle { currentApp = nil; currentBundleID = nil }
        if relaunch {
            try Task.checkCancellation()
            guard app.state == .notRunning else {
                throw CommandError("app_restarted_externally", requiresObservation: true)
            }
            lifecycleFacts?["launchRequested"] = true
            try event { app.launch() }
            lifecycleFacts?["launchAcknowledged"] = true
            guard app.wait(for: .runningForeground, timeout: 5) else {
                throw CommandError("app_not_foreground", requiresObservation: true)
            }
            try checkIssues()
            currentApp = app; currentBundleID = bundle
            lifecycleFacts?["foregroundConfirmed"] = true
            lifecycleFacts?["appState"] = app.state.rawValue
        }
        return lifecycleFacts!
    }
}
