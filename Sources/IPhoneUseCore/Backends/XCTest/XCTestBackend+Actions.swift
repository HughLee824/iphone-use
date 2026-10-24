import IPhoneUseRunnerSupport
import Foundation
import Network
import Darwin

extension XCTestBackend {

    func open(bundle: String) throws -> [String: Any] {
        defer { recording?.checkDisplay() }
        try apps().requireInstalled(bundle)
        let response = try request("launch", fields: ["bundleId": bundle])
        return try ActionReply.decode(response)
    }

    func appLifecycle(bundle: String, relaunch: Bool) throws -> [String: Any] {
        defer { recording?.checkDisplay() }
        try apps().requireInstalled(bundle)
        let response = try request("app-lifecycle", fields: ["bundleId": bundle, "relaunch": relaunch])
        return try Self.lifecycleResponse(response, bundle: bundle, relaunch: relaunch)
    }

    static func lifecycleResponse(_ response: [String: Any], bundle: String, relaunch: Bool) throws
        -> [String: Any] {
        let facts = response["result"] as? [String: Any] ?? [:]
        let execution = response["execution"] as? [String: Any] ?? [:]
        guard response["ok"] as? Bool == true else {
            var failure = response; var result = facts; result["execution"] = execution
            failure["result"] = result
            return try ActionReply.decode(failure)
        }
        // An already-stopped terminate is a verified no-op, with started=false.
        // Do not manufacture an input event merely to satisfy ActionReply.
        let alreadyStopped = facts["alreadyStopped"] as? Bool
        let expectedMutation = relaunch || alreadyStopped == false
        guard execution["started"] as? Bool == expectedMutation, execution["completed"] as? Bool == true,
            alreadyStopped != nil, facts["bundleId"] as? String == bundle,
            facts["operation"] as? String == (relaunch ? "relaunch" : "terminate"),
            facts["stoppedConfirmed"] as? Bool == true,
            facts["terminationRequested"] as? Bool == (alreadyStopped == false),
            facts["terminationAcknowledged"] as? Bool == (alreadyStopped == false),
            facts["launchRequested"] as? Bool == relaunch, facts["launchAcknowledged"] as? Bool == relaunch,
            facts["foregroundConfirmed"] as? Bool == relaunch,
            facts["appState"] as? Int == (relaunch ? 4 : 1)
        else {
            throw ActionFailure(
                code: "missing_app_lifecycle_facts",
                description:
                    "Runner did not confirm the requested lifecycle transition; observe without replay",
                possiblyExecuted: true, requiresObservation: true, result: facts)
        }
        var result = facts; result["execution"] = execution
        return result
    }

    func apps() throws -> AppCatalog {
        guard let deviceUDID else { throw IPhoneUseError("backend_unavailable", "Device is not connected") }
        return try AppCatalog(
            CoreDevice.read(["device", "info", "apps", "--device", deviceUDID, "--include-all-apps"]))
    }

    func perform(_ action: DeviceAction, target: ObservedTarget, onInputStarted: @escaping () -> Void) throws
        -> [String: Any] {
        recording?.checkDisplay()
        defer { recording?.checkDisplay() }
        let response = try request(
            "act", fields: Self.actionFields(action, target: target),
            onInputStarted: target.gesture == nil ? nil : onInputStarted)
        return try ActionReply.decode(
            XCTestCapture.actionResponse(
                response, directory: paths.directory,
                expectedGuard: target.gesture?.screenGuard ?? target.textGuard,
                expectedMotion: target.gesture?.motion,
                expectedPinch: target.gesture?.pinch,
                expectedPressDuration: action.fields["duration"] as? Double,
                expectedHome: action.kind == "home",
                expectedKey: action.kind == "press"
                    ? RunnerPressKey(rawValue: action.fields["key"] as? String ?? "") : nil))
    }

    static func validateCapabilities(_ result: [String: Any]) throws {
        let expected = [
            "observationVersion": 4, "actionVersion": 12, "launchVersion": 2, "frameStabilityVersion": 2,
            "screenGuardVersion": 1, "previewGeometryVersion": 2, "inputProgressVersion": 1
        ]
        var differences = expected.keys.sorted().compactMap { key -> String? in
            let actual = result[key] as? Int
            return actual == expected[key]
                ? nil : "\(key): expected \(expected[key]!), received \(actual.map(String.init) ?? "missing")"
        }
        if result["lifecycleOwner"] as? String != "host" {
            differences.append("lifecycleOwner: expected host")
        }
        if !differences.isEmpty {
            throw IPhoneUseError(
                "runner_needs_rebuild",
                """
                Runner is incompatible (\(differences.joined(separator: "; "))). Release users: install\
                 matching CLI/Runner resources and run setup. Source developers: run build-runner and use its\
                 new .xctestrun
                """
            )
        }
    }

    static func decodePreviewGeometry(_ response: [String: Any]) throws -> RunnerPreviewGeometry {
        guard response["ok"] as? Bool == true, let result = response["result"] as? [String: Any],
            let width = result["width"] as? Int, let height = result["height"] as? Int,
            let orientation = result["orientation"] as? Int, [1, 3, 6, 8].contains(orientation),
            (1...16384).contains(width), (1...16384).contains(height)
        else {
            throw IPhoneUseError(
                "preview_geometry_unavailable", "Runner did not return valid screenshot dimensions")
        }
        return RunnerPreviewGeometry(width: width, height: height, orientation: orientation)
    }

    static func actionFields(_ action: DeviceAction, target: ObservedTarget) throws -> [String: Any] {
        var fields: [String: Any]
        if action.kind == "home" {
            guard let screenGuard = target.textGuard else {
                throw IPhoneUseError("missing_screen_guard", "Home requires the current screenshot")
            }
            fields = ["kind": "home", "screenGuard": try jsonObject(JSONEncoder().encode(screenGuard))]
        } else if ["tap", "double-tap", "long-press", "pinch", "swipe"].contains(action.kind) {
            guard let gesture = target.gesture else {
                throw IPhoneUseError("missing_screen_guard", "Guarded coordinates are required")
            }
            try gesture.validate(kind: action.kind)
            fields = ["kind": action.kind, "gesture": try jsonObject(JSONEncoder().encode(gesture))]
            if action.kind == "long-press" { fields["duration"] = action.fields["duration"] }
        } else {
            fields = action.fields
        }
        var expected: [String: Any] = [
            "scope": target.context["scope"] ?? NSNull(),
            "bundleId": target.context["targetBundleId"] ?? NSNull()
        ]
        if target.gesture == nil && action.kind != "home" {
            expected["path"] = target.path
        }
        fields["target"] = expected
        guard try jsonData(fields).count <= 60_000 else {
            throw IPhoneUseError(
                "target_too_large", "Target or screen guard exceeds the Runner request budget")
        }
        return fields
    }

    func observe() throws -> CapturedObservation {
        recording?.checkDisplay()
        defer { recording?.checkDisplay() }
        let response = try request("observe")
        guard let result = response["result"] as? [String: Any],
            response["ok"] as? Bool == true || result["axStatus"] as? String == "unavailable"
        else {
            throw IPhoneUseError(
                "observe_failed", response["error"] as? String ?? "Runner did not return an observation")
        }
        return try XCTestCapture.decode(result)
    }

    func startRecording(duration: Double) throws -> [String: Any] {
        guard let recording, identity != nil, try runner?.isRunning() == true else {
            throw IPhoneUseError("backend_unavailable", "Runner is not connected")
        }
        return try recording.start(duration: duration)
    }

    func stopRecording(id: String) throws -> [String: Any] {
        guard let recording else { throw IPhoneUseError("backend_unavailable", "Runner is not connected") }
        return try recording.stop(id: id)
    }

    func startPreview(options: NativePreviewOptions = NativePreviewOptions()) throws -> [String: Any] {
        guard let recording else { throw IPhoneUseError("backend_unavailable", "Runner is not connected") }
        return try recording.startPreview(options: options)
    }
    func stopPreview() throws -> [String: Any] { try recording?.stopPreview() ?? ["state": "stopped"] }
    func previewTick() -> Bool { recording?.previewTick() ?? false }
    func showPreviewGesture(_ gesture: NativePreviewGesture) { recording?.showPreviewGesture(gesture) }
    var previewGestureRotation: String? { recording?.previewGestureRotation }
}
