import Foundation
import ImageIO

// Decode the Runner's selected snapshot attributes without parsing debugDescription.
enum XCTestCapture {
    // Keep only the latest action frame; the observation cache clears this directory on disconnect.
    static func actionResponse(
        _ response: [String: Any], directory: URL, expectedGuard: ScreenGuard? = nil,
        expectedMotion: SwipeMotion? = nil, expectedPinch: PinchMotion? = nil,
        expectedPressDuration: Double? = nil, expectedHome: Bool = false, expectedKey: RunnerPressKey? = nil
    ) throws -> [String: Any] {
        var result = response["result"] as? [String: Any] ?? [:]
        result["execution"] = response["execution"]
        result["stability"] = response["stability"]
        result["runnerMs"] = response["runnerMs"]
        result["screenGuard"] = response["screenGuard"]
        let stability = response["stability"] as? [String: Any]
        do {
            try saveFrame(response, stability: stability, directory: directory, result: &result)
            if response["ok"] as? Bool == true, let expectedGuard {
                try validateGuard(response, expectedGuard: expectedGuard)
            }
            if response["ok"] as? Bool == true {
                try validateMotion(
                    result, expectedKey: expectedKey, expectedPinch: expectedPinch,
                    expectedPressDuration: expectedPressDuration, expectedMotion: expectedMotion)
                try validateStability(response, result: result, expectedHome: expectedHome)
            }
        } catch {
            throw ActionFailure(
                code: (error as? IPhoneUseError)?.code ?? "action_frame_unavailable",
                description: String(describing: error), possiblyExecuted: true, requiresObservation: true,
                result: result)
        }
        var decoded = response
        decoded.removeValue(forKey: "stabilityReferenceBase64")
        decoded["result"] = result
        return decoded
    }

    static func decode(_ result: [String: Any]) throws -> CapturedObservation {
        guard let encoded = result["screenshotBase64"] as? String,
            let png = Data(base64Encoded: encoded), png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
            let image = CGImageSourceCreateWithData(png as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any],
            let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
            let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
            width > 0, height > 0
        else {
            throw IPhoneUseError("invalid_screenshot", "Runner did not return a readable PNG")
        }
        var metadata: [String: Any] = [
            "screenshotWidth": width, "screenshotHeight": height,
            "scope": result["scope"] as? String ?? "unknown",
            "targetBundleId": result["targetBundleId"] as? String ?? NSNull(),
            "foregroundBundleId": result["foregroundBundleId"] as? String ?? NSNull(),
            "sourceBundleId": result["bundleId"] as? String ?? NSNull(),
            "screenFrame": result["screenFrame"] as? [String: Any] ?? NSNull()
        ]
        for key in ["snapshotStartedAt", "snapshotFinishedAt", "screenshotCapturedAt"] {
            metadata[key] = result[key] as? Double ?? NSNull()
        }
        metadata["screenContext"] = result["screenContext"] as? [String: Any] ?? NSNull()
        let available = result["axStatus"] as? String == "available"
        metadata["axStatus"] = available ? "available" : "unavailable"
        metadata["sourceTruncated"] = result["truncated"] as? Bool ?? NSNull()
        if !available {
            metadata["axError"] = result["axError"] as? String ?? "AX data was not captured"
            return CapturedObservation(nodes: [], metadata: metadata, screenshot: png)
        }
        guard let rawNodes = result["nodes"] as? [[String: Any]], !rawNodes.isEmpty, rawNodes.count <= 200,
            result["truncated"] is Bool
        else { throw IPhoneUseError("invalid_snapshot", "Invalid AX node list or capture limit") }
        let nodes = try rawNodes.enumerated().map { index, attributes -> AXNode in
            let parent = attributes["parent"] as? Int
            guard attributes["index"] as? Int == index,
                (index == 0 ? attributes["parent"] is NSNull : parent.map { $0 >= 0 && $0 < index } == true),
                let type = attributes["type"] as? Int, type >= 0,
                attributes["label"] is String, attributes["identifier"] is String,
                attributes["enabled"] is Bool,
                let frame = attributes["frame"] as? [String: Any],
                ["x", "y", "width", "height"].allSatisfy({ (frame[$0] as? Double)?.isFinite == true })
            else {
                throw IPhoneUseError("invalid_snapshot", "Invalid attributes or parent at AX node \(index)")
            }
            return AXNode(
                index: index, parent: parent, role: roles[type] ?? "type_\(type)", attributes: attributes)
        }
        return CapturedObservation(nodes: nodes, metadata: metadata, screenshot: png)
    }

    // XCUIElementType values from the installed public XCTest SDK header.
    private static let roles = [
        0: "any", 1: "group", 2: "application", 3: "group", 4: "window",
        5: "sheet", 6: "drawer", 7: "alert", 8: "dialog", 9: "button", 10: "radio_button",
        11: "radio_group", 12: "check_box", 13: "disclosure_triangle", 14: "pop_up_button",
        15: "combo_box", 16: "menu_button", 17: "toolbar_button", 18: "popover", 19: "keyboard",
        20: "key", 21: "navigation_bar", 22: "tab_bar", 23: "tab_group", 24: "toolbar",
        25: "status_bar", 26: "table", 27: "table_row", 28: "table_column", 29: "outline",
        30: "outline_row", 31: "browser", 32: "collection_view", 33: "slider", 34: "page_indicator",
        35: "progress_indicator", 36: "activity_indicator", 37: "segmented_control", 38: "picker",
        39: "picker_wheel", 40: "switch", 41: "toggle", 42: "link", 43: "image", 44: "icon",
        45: "search_field", 46: "scroll_view", 47: "scroll_bar", 48: "text", 49: "text_field",
        50: "secure_text_field", 51: "date_picker", 52: "text_view", 53: "menu", 54: "menu_item",
        55: "menu_bar", 56: "menu_bar_item", 57: "map", 58: "web_view", 75: "cell"
    ]
}

extension XCTestCapture {
    private static func saveFrame(
        _ response: [String: Any], stability: [String: Any]?,
        directory: URL, result: inout [String: Any]
    ) throws {
        if let frame = response["frame"] as? [String: Any] {
            guard let encoded = frame["screenshotBase64"] as? String, let png = Data(base64Encoded: encoded),
                let capturedAt = frame["capturedAt"] as? Double, capturedAt.isFinite
            else {
                throw IPhoneUseError("invalid_action_frame", "Runner did not return a valid action frame")
            }
            let fingerprint = try FrameFingerprint(png: png)
            guard frame["hash"] as? String == fingerprint.hash,
                stability?["hash"] as? String == fingerprint.hash,
                frame["width"] as? Int == fingerprint.width, frame["height"] as? Int == fingerprint.height
            else {
                throw IPhoneUseError(
                    "invalid_action_frame", "Action frame does not match its stability evidence")
            }
            let frames = directory.appendingPathComponent("observations/action")
            try SessionPaths.secureDirectory(frames)
            for name in ["reference.png", "difference.png"] {
                let old = frames.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: old.path) {
                    try FileManager.default.removeItem(at: old)
                }
            }
            let file = frames.appendingPathComponent("screen.png")
            try png.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            result["frame"] = [
                "screenshot": file.path, "hash": fingerprint.hash, "capturedAt": capturedAt,
                "width": fingerprint.width, "height": fingerprint.height
            ]
            if let encodedReference = response["stabilityReferenceBase64"] as? String {
                result["stabilityDiagnostic"] = try saveStabilityDiagnostic(
                    encodedReference,
                    expectedHash: stability?["referenceHash"] as? String, fingerprint: fingerprint,
                    frames: frames)
            }
        }
    }

    private static func validateGuard(_ response: [String: Any], expectedGuard: ScreenGuard) throws {
        guard let evidence = response["screenGuard"] as? [String: Any],
            evidence["accepted"] as? Bool == true,
            evidence["algorithm"] as? String == expectedGuard.algorithm,
            evidence["maxScreenChange"] as? Double == expectedGuard.policy.maxScreenChange,
            evidence["maxRegionChange"] as? Double == expectedGuard.policy.maxRegionChange,
            let global = evidence["screenChange"] as? Double, global.isFinite,
            (0...(expectedGuard.dynamicOverlay == nil ? expectedGuard.policy.maxScreenChange : 1)).contains(
                global),
            let regions = evidence["regionChanges"] as? [Double],
            regions.count == (expectedGuard.dynamicOverlay == nil ? expectedGuard.regions.count : 0),
            regions.allSatisfy({ $0.isFinite && (0...expectedGuard.policy.maxRegionChange).contains($0) })
        else {
            throw IPhoneUseError(
                "missing_screen_guard_facts",
                "Runner did not confirm the requested screen guard; observe before deciding what to do next")
        }
        if expectedGuard.dynamicOverlay != nil {
            guard evidence["dynamicMatches"] as? [Bool] == [true, true],
                evidence["validationScope"] as? String == "explicit_target_and_anchor"
            else {
                throw IPhoneUseError(
                    "missing_screen_guard_facts", "Runner did not confirm both dynamic overlay regions")
            }
        } else if evidence["dynamicMatches"] != nil {
            throw IPhoneUseError("missing_screen_guard_facts", "Unexpected dynamic overlay validation")
        }
        if let rect = expectedGuard.ignoredRect {
            guard let raw = evidence["ignoredRect"] as? [String: Any],
                let actual = try? JSONDecoder().decode(ScreenRect.self, from: jsonData(raw)), actual == rect,
                evidence["exclusionScope"] as? String == "global_comparison_only",
                let rawChange = evidence["rawScreenChange"] as? Double, rawChange.isFinite,
                (0...1).contains(rawChange)
            else {
                throw IPhoneUseError(
                    "missing_screen_guard_facts", "Runner did not confirm the requested animation rectangle")
            }
        } else if evidence["ignoredRect"] != nil {
            throw IPhoneUseError(
                "missing_screen_guard_facts", "Runner unexpectedly excluded an animation rectangle")
        }
    }

    private static func validateMotion(
        _ result: [String: Any], expectedKey: RunnerPressKey?,
        expectedPinch: PinchMotion?, expectedPressDuration: Double?,
        expectedMotion: SwipeMotion?
    ) throws {
        if let expectedKey {
            guard result["key"] as? String == expectedKey.rawValue,
                result["keyModifiers"] as? [String] == expectedKey.modifiers
            else {
                throw IPhoneUseError(
                    "missing_key_facts", "Runner did not confirm the requested key and modifiers")
            }
        }
        if let expectedPinch {
            guard let raw = result["pinch"] as? [String: Any],
                let actual = try? JSONDecoder().decode(PinchMotion.self, from: jsonData(raw)),
                actual == expectedPinch,
                raw["axis"] as? String == "screenshot_horizontal",
                raw["distanceUnit"] as? String == "screen_points"
            else {
                throw IPhoneUseError(
                    "missing_pinch_motion_facts",
                    "Runner did not confirm the requested pinch paths and duration")
            }
        }
        if let expectedPressDuration, result["duration"] as? Double != expectedPressDuration {
            throw IPhoneUseError(
                "missing_press_duration_facts", "Runner did not confirm the requested long press duration")
        }
        if let expectedMotion {
            guard let raw = result["motion"] as? [String: Any],
                let actual = try? JSONDecoder().decode(SwipeMotion.self, from: jsonData(raw)),
                actual == expectedMotion
            else {
                throw IPhoneUseError(
                    "missing_swipe_motion_facts",
                    """
                    Runner did not confirm the requested swipe speed and holds; observe before\
                     deciding what to do next
                    """
                )
            }
        }
    }

    private static func validateStability(
        _ response: [String: Any], result: [String: Any], expectedHome: Bool
    ) throws {
        let execution = response["execution"] as? [String: Any]
        let stability = response["stability"] as? [String: Any]
        if expectedHome {
            guard execution?["inputCompleted"] as? Bool == true, result["kind"] as? String == "home",
                result["homePressCompleted"] as? Bool == true, result["homeScreenConfirmed"] as? Bool == false
            else {
                throw IPhoneUseError("missing_home_facts", "Runner did not confirm Home input completion")
            }
        } else if stability?["stable"] as? Bool == false {
            guard execution?["inputCompleted"] as? Bool == true,
                stability?["reason"] as? String == "dynamic_or_transitioning",
                stability?["automaticReplayAllowed"] as? Bool == false,
                stability?["algorithm"] as? String == FrameComparison.algorithm,
                let samples = stability?["samples"] as? Int, samples >= 3,
                let observed = stability?["observedForMs"] as? Double, observed.isFinite,
                observed >= FrameStability.minimumObservationDuration * 1000,
                let elapsed = stability?["elapsedMs"] as? Double, elapsed.isFinite, elapsed >= observed,
                response["frame"] is [String: Any], result["frame"] != nil
            else {
                throw IPhoneUseError(
                    "missing_stability_facts",
                    "Runner did not confirm input completion and a fresh dynamic observation")
            }
        } else {
            guard execution?["inputCompleted"] as? Bool == true, stability?["stable"] as? Bool == true,
                stability?["algorithm"] as? String == FrameComparison.algorithm,
                stability?["minimumObservationMs"] as? Double == FrameStability.minimumObservationDuration
                    * 1000,
                let observed = stability?["observedForMs"] as? Double, observed.isFinite,
                observed >= FrameStability.minimumObservationDuration * 1000,
                let comparison = stability?["comparison"] as? [String: Any],
                comparison["equivalent"] as? Bool == true, comparison["dimensionsMatch"] as? Bool == true,
                comparison["changedPixels"] as? Int == 0,
                comparison["colorTolerance"] as? Double == FrameComparison.colorTolerance,
                comparison["maxChannelDelta"] as? Int == 4,
                let frames = stability?["consecutiveFrames"] as? Int, frames >= 3,
                let stableFor = stability?["stableForMs"] as? Double,
                stableFor >= FrameStability.stableDuration * 1000,
                let elapsed = stability?["elapsedMs"] as? Double, elapsed.isFinite,
                elapsed >= observed, observed >= stableFor, elapsed < FrameStability.timeout * 1000,
                response["frame"] is [String: Any], result["frame"] != nil
            else {
                throw IPhoneUseError(
                    "missing_stability_facts", "Runner did not confirm input completion and frame stability")
            }
        }
    }
    private static func saveStabilityDiagnostic(
        _ encodedReference: String, expectedHash: String?,
        fingerprint: FrameFingerprint, frames: URL
    ) throws -> [String: Any] {
        guard let referencePNG = Data(base64Encoded: encodedReference) else {
            throw IPhoneUseError("invalid_action_frame", "Invalid stability reference image")
        }
        let reference = try FrameFingerprint(png: referencePNG)
        guard reference.hash == expectedHash else {
            throw IPhoneUseError("invalid_action_frame", "Stability reference hash mismatch")
        }
        let referenceFile = frames.appendingPathComponent("reference.png")
        try referencePNG.write(to: referenceFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: referenceFile.path)
        var diagnostic: [String: Any] = ["reference": referenceFile.path, "referenceHash": reference.hash]
        if reference.width == fingerprint.width && reference.height == fingerprint.height {
            let diffFile = frames.appendingPathComponent("difference.png")
            try fingerprint.differencePNG(from: reference).write(to: diffFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: diffFile.path)
            diagnostic["difference"] = diffFile.path
            diagnostic["differenceKind"] = "all_raw_pixel_changes"
        }
        return diagnostic
    }
}
