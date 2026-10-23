import XCTest
import CoreGraphics
import ImageIO
@testable import IPhoneUseCore

extension ScreenGuardTests {

    func testUnnamedSiblingControlsResolveToCoordinatesWithoutSendingAXPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guard-targets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory), fixture = try observationFixture()
        var nodes = [fixture.nodes[0]]
        for index in 1...2 {
            let attributes: [String: Any] = [
                "index": index, "parent": 0, "type": 46, "identifier": "", "label": "", "enabled": true,
                "value": NSNull(),
                "frame": ["x": Double(index - 1) * 195, "y": 265.0, "width": 195.0, "height": 240.0]
            ]
            nodes.append(AXNode(index: index, parent: 0, role: "scroll_view", attributes: attributes))
        }
        _ = try cache.store(
            CapturedObservation(nodes: nodes, metadata: fixture.metadata, screenshot: fixture.screenshot))
        for index in 1...2 {
            let action = try DeviceAction(
                operation: "swipe", request: ["reference": "o1:e\(index + 1)", "direction": "up"])
            let target = try cache.resolveTarget(for: action)
            let gesture = try XCTUnwrap(target.gesture)
            XCTAssertEqual(gesture.start.x, Double(index - 1) * 195 + 97.5)
            XCTAssertEqual(gesture.start.y, 457)
            XCTAssertEqual(gesture.end?.y, 313)
            XCTAssertTrue(target.path.isEmpty)
            let fields = try XCTestBackend.actionFields(action, target: target)
            XCTAssertNil((fields["target"] as? [String: Any])?["path"])
            XCTAssertFalse(
                (try XCTUnwrap(String(data: try jsonData(fields), encoding: .utf8))).contains("o1:e"))
        }
    }

    func testExplicitSwipeAndMaximumProtectionFitWireBudget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guard-budget-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        _ = try cache.store(observationFixture())
        let action = try DeviceAction(
            operation: "swipe",
            request: [
                "reference": "o1", "fromX": 100, "fromY": 600,
                "toX": 100, "toY": 200, "protect": ["o1:e1", "o1:e1", "o1:e1"]
            ])
        let target = try cache.resolveTarget(for: action)
        XCTAssertEqual(target.gesture?.screenGuard.regions.count, 5)
        XCTAssertLessThan(try jsonData(XCTestBackend.actionFields(action, target: target)).count, 60_000)
        let point = try DeviceAction(operation: "tap", request: ["reference": "o1", "x": 500, "y": 30])
        XCTAssertThrowsError(try cache.resolveTarget(for: point))
        XCTAssertNoThrow(try cache.resolveCurrent(ObservationReference("o1:e1")))
    }

    func testGuardRejectionPreservesNoInputFactsAndScoresInActionReply() throws {
        let response: [String: Any] = [
            "ok": false, "errorCode": "screen_changed", "requiresObservation": true,
            "execution": ["started": false, "inputCompleted": false, "completed": false],
            "screenGuard": ["accepted": false, "screenChange": 0.001, "regionChanges": [0.2]]
        ]
        let decoded = try XCTestCapture.actionResponse(
            response, directory: FileManager.default.temporaryDirectory)
        XCTAssertThrowsError(try ActionReply.decode(decoded)) { error in
            let failure = error as? ActionFailure
            XCTAssertEqual(failure?.possiblyExecuted, false)
            XCTAssertEqual(failure?.requiresObservation, true)
            XCTAssertEqual(
                (failure?.result?["screenGuard"] as? [String: Any])?["screenChange"] as? Double, 0.001)
        }
    }

    func testOlderRunnerCannotSilentlySkipScreenGuards() throws {
        let supported: [String: Any] = [
            "lifecycleOwner": "host", "observationVersion": 2, "actionVersion": 9,
            "launchVersion": 2, "frameStabilityVersion": 2, "screenGuardVersion": 1,
            "previewGeometryVersion": 2,
            "inputProgressVersion": 1
        ]
        XCTAssertNoThrow(try XCTestBackend.validateCapabilities(supported))
        for key in [
            "observationVersion", "actionVersion", "launchVersion", "screenGuardVersion",
            "frameStabilityVersion",
            "previewGeometryVersion", "inputProgressVersion"
        ] {
            var older = supported
            older[key] = 0
            XCTAssertThrowsError(try XCTestBackend.validateCapabilities(older))
        }
        var withoutMotion = supported
        withoutMotion["actionVersion"] = 4
        XCTAssertThrowsError(try XCTestBackend.validateCapabilities(withoutMotion)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "runner_needs_rebuild")
        }
    }

    func testSwipeSuccessMustConfirmRequestedMotion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swipe-receipt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try screenPNG(), frame = try FrameFingerprint(png: png)
        let motion = SwipeMotion(velocity: 100, pressDuration: 0.5, holdDuration: 0.2)
        var response: [String: Any] = [
            "ok": true, "result": ["kind": "swipe", "motion": motion.result],
            "execution": ["started": true, "inputCompleted": true, "completed": true],
            "stability": [
                "stable": true, "hash": frame.hash, "consecutiveFrames": 3, "stableForMs": 400.0,
                "elapsedMs": 1600.0,
                "algorithm": FrameComparison.algorithm, "minimumObservationMs": 1500.0,
                "observedForMs": 1500.0,
                "comparison": [
                    "equivalent": true, "dimensionsMatch": true, "changedPixels": 0, "colorTolerance": 2.5,
                    "maxChannelDelta": 4
                ]
            ],
            "frame": [
                "hash": frame.hash, "width": frame.width, "height": frame.height, "capturedAt": 100.0,
                "screenshotBase64": png.base64EncodedString()
            ]
        ]
        let result = try ActionReply.decode(
            XCTestCapture.actionResponse(response, directory: directory, expectedMotion: motion))
        XCTAssertEqual((result["motion"] as? [String: Any])?["velocity"] as? Double, 100)
        for value: Any in [
            NSNull(), SwipeMotion().result, ["velocity": 100, "pressDuration": 0.5],
            ["velocity": 100, "pressDuration": 0.5, "holdDuration": 0]
        ] {
            response["result"] = ["kind": "swipe", "motion": value]
            XCTAssertThrowsError(
                try XCTestCapture.actionResponse(response, directory: directory, expectedMotion: motion)
            ) {
                let failure = $0 as? ActionFailure
                XCTAssertEqual(failure?.code, "missing_swipe_motion_facts")
                XCTAssertEqual(failure?.possiblyExecuted, true)
                XCTAssertEqual(failure?.requiresObservation, true)
                XCTAssertNotNil(failure?.result?["frame"])
            }
        }
    }

    func testClaimedSuccessRequiresConsistentGuardEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guard-evidence-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try screenPNG(), expected = try guardValue(), frame = try FrameFingerprint(png: png)
        let proof = try expected.check(png: png, context: screenTestContext()).result
        var response = actionResponse(proof: proof, frame: frame, png: png)
        XCTAssertNoThrow(
            try ActionReply.decode(
                XCTestCapture.actionResponse(response, directory: directory, expectedGuard: expected)))
        for (key, value): (String, Any) in [
            ("accepted", false), ("algorithm", "other"), ("maxScreenChange", 1.0),
            ("screenChange", 0.2), ("regionChanges", []), ("regionChanges", [0.1])
        ] {
            var evidence = proof
            evidence[key] = value
            response["screenGuard"] = evidence
            XCTAssertThrowsError(
                try XCTestCapture.actionResponse(response, directory: directory, expectedGuard: expected)
            ) {
                XCTAssertEqual(($0 as? ActionFailure)?.code, "missing_screen_guard_facts")
                XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true)
                XCTAssertNotNil(($0 as? ActionFailure)?.result?["frame"])
            }
        }
        let video = ScreenRect(CGRect(x: 30, y: 100, width: 120, height: 160))
        let masked = try ScreenGuard(
            png: png, context: screenTestContext(), rects: expected.regions.map(\.rect), policy: .init(),
            ignoring: video)
        let maskedProof = try masked.check(png: png, context: screenTestContext()).result
        response["screenGuard"] = maskedProof
        XCTAssertNoThrow(
            try XCTestCapture.actionResponse(response, directory: directory, expectedGuard: masked))
        for key in ["ignoredRect", "rawScreenChange", "exclusionScope"] {
            var evidence = maskedProof; evidence.removeValue(forKey: key); response["screenGuard"] = evidence
            XCTAssertThrowsError(
                try XCTestCapture.actionResponse(response, directory: directory, expectedGuard: masked))
        }
        response["screenGuard"] = maskedProof
        XCTAssertThrowsError(
            try XCTestCapture.actionResponse(response, directory: directory, expectedGuard: expected))
        response.removeValue(forKey: "screenGuard")
        XCTAssertThrowsError(
            try XCTestCapture.actionResponse(response, directory: directory, expectedGuard: expected))
    }
    private func actionResponse(proof: [String: Any], frame: FrameFingerprint, png: Data) -> [String: Any] {
        let response: [String: Any] = [
            "ok": true, "screenGuard": proof,
            "execution": ["started": true, "inputCompleted": true, "completed": true],
            "stability": [
                "stable": true, "hash": frame.hash, "consecutiveFrames": 3, "stableForMs": 400.0,
                "elapsedMs": 1600.0,
                "algorithm": FrameComparison.algorithm, "minimumObservationMs": 1500.0,
                "observedForMs": 1500.0,
                "comparison": [
                    "equivalent": true, "dimensionsMatch": true, "changedPixels": 0, "colorTolerance": 2.5,
                    "maxChannelDelta": 4
                ]
            ],
            "frame": [
                "hash": frame.hash, "width": frame.width, "height": frame.height, "capturedAt": 100.0,
                "screenshotBase64": png.base64EncodedString()
            ]
        ]
        return response
    }
}
