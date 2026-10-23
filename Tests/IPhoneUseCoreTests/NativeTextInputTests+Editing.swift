import XCTest
@testable import IPhoneUseCore

extension NativeTextInputTests {

    func testEditingModesValidateWholePayloadBeforeAnyShortcutAndEmptyReplaceAvoidsClipboard() throws {
        for mode in ["insert", "replace", "append"] {
            guard case .pasteboard(let value) = try NativeTextInput(text: "中文🙂", mode: mode) else {
                return XCTFail("Expected paste")
            }
            XCTAssertEqual(value, "中文🙂")
            guard case .keyboard(let keys) = try NativeTextInput(text: "Ab", mode: mode) else {
                return XCTFail("Expected keys")
            }
            XCTAssertEqual(keys, [[225, 4], [5]])
            XCTAssertThrowsError(try NativeTextInput(text: "中文", mode: mode, method: "keys"))
            XCTAssertThrowsError(try NativeTextInput(text: "abc\t", mode: mode))
            XCTAssertThrowsError(
                try NativeTextInput(text: String(repeating: "a", count: 4097), mode: mode, method: "paste"))
        }
        for method in ["auto", "keys", "paste"] {
            let plan = try NativeTextInput(text: "", mode: "replace", method: method)
            guard case .clear = plan else { return XCTFail("Expected no-clipboard deletion") }
            XCTAssertFalse(plan.usesPasteboard)
            for mode in ["insert", "append"] {
                XCTAssertThrowsError(try NativeTextInput(text: "", mode: mode, method: method))
            }
        }
        XCTAssertThrowsError(try NativeTextInput(text: "", mode: "replace", method: "invalid"))
    }

    func testNativeAppendKeepsScreenOnlyObservationGuard() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory), context = screenTestContext()
        _ = try cache.store(
            CapturedObservation(
                nodes: [],
                metadata: [
                    "backend": "apple-native",
                    "screenContext": try jsonObject(JSONEncoder().encode(context))
                ], screenshot: try screenPNG()))
        for mode in ["insert", "replace", "append"] {
            let request: [String: Any] = [
                "reference": "o1", "mode": mode, "text": "abc", "fieldRect": "18,146,354,36"
            ]
            let action = try DeviceAction(operation: "type", request: request, allowScreenText: true)
            XCTAssertEqual(action.fields["mode"] as? String, mode)
            let guardValue = try XCTUnwrap(cache.resolveTarget(for: action).textGuard)
            XCTAssertEqual(guardValue.policy.maxRegionChange, 0)
            let changed = try screenPNG(patches: [(CGRect(x: 50, y: 160, width: 4, height: 10), [0, 0, 0])])
            XCTAssertFalse(try guardValue.check(png: changed, context: context).accepted)
        }
        for native in [false, true] {
            let action = try DeviceAction(
                operation: "type", request: ["reference": "o1:e1", "mode": "append", "text": "abc"],
                allowScreenText: native)
            XCTAssertThrowsError(try cache.resolveTarget(for: action))
        }
        XCTAssertThrowsError(
            try DeviceAction(
                operation: "type", request: ["reference": "o1", "mode": "append", "text": ""],
                allowScreenText: true))
    }

    func testRotationChangeRejectsIdenticalPixelsWithoutRetryAndPreservesNewFrame() throws {
        let screen = ScreenRect(CGRect(x: 0, y: 0, width: 844, height: 390))
        let context = ScreenContext(screen: screen, scope: screen, orientation: 4, keyboardCount: 0)
        let png = try screenPNG(width: 844, height: 390)
        let guardValue = try ScreenGuard(png: png, context: context, rects: [screen], policy: .init())
        // Left and right landscape have identical sizes. Orientation, not image
        // similarity, must stop a stale action even on a uniform screen.
        for (rotation, native, orientation) in [
            ("rot270", "rot0", 3), ("rot90", "rot90", 4), ("rot90", "rot0", 3)
        ] {
            var calls = 0
            XCTAssertThrowsError(
                try NativeInputPreflight.check(
                    guard: guardValue, displayID: 1, displayRotation: "rot90",
                    deadline: 8, maximumCaptures: 3, now: { 0 },
                    capture: {
                        calls += 1
                        let changed = ScreenContext(
                            screen: screen, scope: screen, orientation: orientation, keyboardCount: 0)
                        return CapturedObservation(
                            nodes: [],
                            metadata: [
                                "displayID": UInt64(1), "displayRotation": rotation,
                                "nativeRotation": native,
                                "screenContext": try jsonObject(JSONEncoder().encode(changed))
                            ], screenshot: png)
                    })
            ) {
                let failure = $0 as? ActionFailure
                XCTAssertEqual(failure?.possiblyExecuted, false)
                XCTAssertEqual(failure?.requiresObservation, true)
                XCTAssertEqual(failure?.result?["screenContextChanged"] as? Bool, true)
                XCTAssertEqual(failure?.rejectedCapture?.screenshot, png)
            }
            XCTAssertEqual(calls, 1)
        }
    }

    func testReadOnlyPreflightAlwaysUsesOriginalGuardAndHasBoundedAttempts() throws {
        let context = screenTestContext(), baseline = try screenPNG()
        let changed = try screenPNG(patches: [(CGRect(x: 50, y: 160, width: 4, height: 10), [0, 0, 0])])
        let guardValue = try ScreenGuard(
            png: baseline, context: context,
            rects: [ScreenRect(CGRect(x: 18, y: 146, width: 354, height: 36))], policy: .init())
        let metadata: [String: Any] = [
            "displayID": UInt64(1), "screenContext": try jsonObject(JSONEncoder().encode(context))
        ]
        var count = 0
        let result = try NativeInputPreflight.check(
            guard: guardValue, displayID: 1, deadline: 8, maximumCaptures: 3, now: { Double(count) },
            capture: {
                count += 1
                return CapturedObservation(
                    nodes: [], metadata: metadata, screenshot: count == 3 ? baseline : changed)
            })
        XCTAssertEqual(result.1, 3)
        XCTAssertEqual(result.0.regionChanges, [0])
        count = 0
        XCTAssertThrowsError(
            try NativeInputPreflight.check(
                guard: guardValue, displayID: 1, deadline: 8, maximumCaptures: 3, now: { Double(count) },
                capture: {
                    count += 1
                    return CapturedObservation(nodes: [], metadata: metadata, screenshot: changed)
                })
        ) {
            XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, false)
            XCTAssertEqual(($0 as? ActionFailure)?.rejectedCapture?.screenshot, changed)
        }
        XCTAssertEqual(count, 3)
        // Identical changed frames never establish a new baseline.
    }

    func testPreflightTracePreservesEachComparisonWithoutChangingBaseline() throws {
        let context = screenTestContext(), baseline = try screenPNG()
        let changed = try screenPNG(patches: [(CGRect(x: 50, y: 160, width: 4, height: 10), [0, 0, 0])])
        let guardValue = try ScreenGuard(
            png: baseline, context: context,
            rects: [ScreenRect(CGRect(x: 18, y: 146, width: 354, height: 36))], policy: .init())
        let metadata: [String: Any] = [
            "displayID": UInt64(1), "screenContext": try jsonObject(JSONEncoder().encode(context))
        ]
        for restoresBaseline in [false, true] {
            var time = 0.0, captures = 0, records: [[String: Any]] = []
            func run() throws -> (ScreenGuard.Check, Int) {
                try NativeInputPreflight.check(
                    guard: guardValue, displayID: 1, deadline: 8, maximumCaptures: 3,
                    now: { time }, record: { records.append($0) },
                    capture: {
                        captures += 1; time += 1
                        return CapturedObservation(
                            nodes: [], metadata: metadata,
                            screenshot: restoresBaseline && captures == 3 ? baseline : changed)
                    })
            }
            if restoresBaseline {
                XCTAssertTrue(try run().0.accepted)
            } else {
                XCTAssertThrowsError(try run()) {
                    guard let failure = $0 as? ActionFailure else { return XCTFail("Expected ActionFailure") }
                    XCTAssertFalse(failure.possiblyExecuted)
                }
            }
            XCTAssertEqual(captures, 3)
            XCTAssertEqual(records.compactMap { $0["attempt"] as? Int }, [1, 2, 3])
            XCTAssertEqual(records.compactMap { $0["elapsedMs"] as? Double }, [1000, 2000, 3000])
            XCTAssertEqual(records.compactMap { $0["captureAndCheckMs"] as? Double }, [1000, 1000, 1000])
            XCTAssertEqual(
                records.compactMap { ($0["screenGuard"] as? [String: Any])?["accepted"] as? Bool },
                [false, false, restoresBaseline])
            XCTAssertTrue(records.allSatisfy { $0["inTime"] as? Bool == true })
        }
    }

    func testPreflightTraceRecordsLateMatchButNeverAuthorizesIt() throws {
        let context = screenTestContext(), baseline = try screenPNG()
        let guardValue = try ScreenGuard(
            png: baseline, context: context, rects: [context.screen], policy: .init())
        var time = 0.0, records: [[String: Any]] = []
        XCTAssertThrowsError(
            try NativeInputPreflight.check(
                guard: guardValue, displayID: 1,
                deadline: 8, maximumCaptures: 3, now: { time }, record: { records.append($0) },
                capture: {
                    time = 9
                    return CapturedObservation(
                        nodes: [],
                        metadata: [
                            "displayID": UInt64(1),
                            "screenContext": try jsonObject(JSONEncoder().encode(context))
                        ], screenshot: baseline)
                })
        ) {
            guard let failure = $0 as? ActionFailure else { return XCTFail("Expected ActionFailure") }
            XCTAssertFalse(failure.possiblyExecuted)
        }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["inTime"] as? Bool, false)
        XCTAssertEqual((records[0]["screenGuard"] as? [String: Any])?["accepted"] as? Bool, true)
    }
}
