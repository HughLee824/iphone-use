import XCTest
@testable import IPhoneUseCore

final class NativeTextInputTests: XCTestCase {
    func testExplicitPasteAcceptsLongASCIIAndKeysNeverFallBackToClipboard() throws {
        let text = String(repeating: "Ab7 ?", count: 819) + "!"
        XCTAssertEqual(text.utf8.count, 4096)
        guard case .pasteboard(let payload) = try NativeTextInput(text: text, mode: "insert", method: "paste") else { return XCTFail("Expected literal paste") }
        XCTAssertEqual(payload, text)
        XCTAssertThrowsError(try NativeTextInput(text: text + "!", mode: "insert", method: "paste"))
        for method in ["keys", "auto"] { XCTAssertThrowsError(try NativeTextInput(text: text, mode: "insert", method: method)) }
        XCTAssertThrowsError(try NativeTextInput(text: "中文", mode: "insert", method: "keys"))
        XCTAssertThrowsError(try NativeTextInput(text: "abc", mode: "insert", method: "invalid"))
        XCTAssertThrowsError(try NativeTextInput(text: "abc\t", mode: "insert", method: "paste"))
    }

    func testMultilinePastePreservesBytesAndNeverSynthesizesReturn() throws {
        for text in ["one\ntwo\n", "第一行🙂\n\n末行", "one\r\ntwo", "one\rtwo"] {
            for mode in ["insert", "replace", "append"] {
                for method in ["auto", "paste"] {
                    let action = try DeviceAction(operation: "type", request: ["reference": "o1", "mode": mode,
                        "text": text, "textMethod": method], allowScreenText: true)
                    let payload = try XCTUnwrap(action.fields["text"] as? String)
                    guard case .pasteboard(let value) = try NativeTextInput(text: payload, mode: mode, method: method) else {
                        return XCTFail("Line breaks must never generate keyboard Return reports")
                    }
                    XCTAssertEqual(Array(value.utf8), Array(text.utf8))
                }
                XCTAssertThrowsError(try NativeTextInput(text: text, mode: mode, method: "keys"))
                XCTAssertThrowsError(try DeviceAction(operation: "type", request: ["reference": "o1", "mode": mode,
                    "text": text, "textMethod": "keys"], allowScreenText: true))
            }
            XCTAssertNoThrow(try DeviceAction(operation: "type", request: ["reference": "o1", "mode": "insert", "text": text], allowScreenText: true))
            XCTAssertThrowsError(try DeviceAction(operation: "type", request: ["reference": "o1:e1", "mode": "insert", "text": text]))
        }
        for text in ["a\n\u{0}", "a\n\t", "a\r\u{1b}", "a\n\u{7f}", "a\n\u{2028}"] {
            XCTAssertThrowsError(try NativeTextInput(text: text, mode: "insert", method: "paste"))
            XCTAssertThrowsError(try DeviceAction(operation: "type", request: ["reference": "o1", "mode": "insert", "text": text], allowScreenText: true))
        }
        let limit = String(repeating: "a", count: 4095) + "\n"
        guard case .pasteboard(let value) = try NativeTextInput(text: limit, mode: "insert") else { return XCTFail("Expected paste") }
        XCTAssertEqual(value.utf8.count, 4096)
        XCTAssertThrowsError(try NativeTextInput(text: limit + "a", mode: "insert"))
    }

    func testMethodSurvivesActionAndObservationResolutionAndRejectsRunner() throws {
        let request: [String: Any] = ["reference": "o1", "mode": "insert", "text": String(repeating: "a", count: 100), "textMethod": "paste"]
        let action = try DeviceAction(operation: "type", request: request, allowScreenText: true)
        XCTAssertEqual(action.fields["textMethod"] as? String, "paste")
        XCTAssertThrowsError(try DeviceAction(operation: "type", request: request))
        XCTAssertThrowsError(try DeviceAction(operation: "tap", request: request, allowScreenText: true))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        let frame = CapturedObservation(nodes: [], metadata: ["backend": "apple-native", "screenContext": try jsonObject(JSONEncoder().encode(screenTestContext()))], screenshot: try screenPNG())
        _ = try cache.store(frame)
        XCTAssertNotNil(try cache.resolveTarget(for: action).textGuard)
        XCTAssertEqual(try cache.resolveTextConfirmation(ObservationReference("o1"))["backend"] as? String, "apple-native")
        XCTAssertThrowsError(try cache.resolveTextConfirmation(ObservationReference("o1:e1")))
        _ = try cache.store(frame)
        XCTAssertThrowsError(try cache.resolveTextConfirmation(ObservationReference("o1")))
    }

    func testUnicodeResolvesThroughObservationCacheAndStillRequiresCurrentSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = screenTestContext(), cache = ObservationCache(directory: directory)
        let frame = CapturedObservation(nodes: [], metadata: ["backend": "apple-native",
            "screenContext": try jsonObject(JSONEncoder().encode(context))], screenshot: try screenPNG())
        _ = try cache.store(frame)
        let action = try DeviceAction(operation: "type", request: ["reference": "o1", "mode": "insert", "text": "中文 A🙂"], allowScreenText: true)
        let target = try cache.resolveTarget(for: action)
        XCTAssertEqual(target.textGuard?.regions.map(\.rect), [context.screen])
        _ = try cache.store(frame)
        XCTAssertThrowsError(try cache.resolveTarget(for: action))
    }
    func testUnicodeIsOneWholePayloadAndExistingASCIIContractIsPreserved() throws {
        for text in ["中文", "中英 A7，🙂", "e\u{301}", "👩‍💻", String(repeating: "中", count: 1365)] {
            guard case .pasteboard(let value) = try NativeTextInput(text: text, mode: "insert") else { return XCTFail("Unicode must not be partially sent as keys") }
            XCTAssertEqual(Array(value.utf8), Array(text.utf8))
        }
        guard case .keyboard(let keys) = try NativeTextInput(text: "Ab7!?", mode: "insert") else { return XCTFail("ASCII changed") }
        XCTAssertEqual(keys, try NativeKeyboard.keys(for: "Ab7!?", mode: "insert"))
        for text in ["", "中\t文", "中\u{85}", "中\u{2028}", String(repeating: "中", count: 1366), String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try NativeTextInput(text: text, mode: "insert"))
        }
        XCTAssertThrowsError(try NativeTextInput(text: "中文", mode: "unknown"))
    }

    func testEditingModesValidateWholePayloadBeforeAnyShortcutAndEmptyReplaceAvoidsClipboard() throws {
        for mode in ["insert", "replace", "append"] {
            guard case .pasteboard(let value) = try NativeTextInput(text: "中文🙂", mode: mode) else { return XCTFail("Expected paste") }
            XCTAssertEqual(value, "中文🙂")
            guard case .keyboard(let keys) = try NativeTextInput(text: "Ab", mode: mode) else { return XCTFail("Expected keys") }
            XCTAssertEqual(keys, [[225, 4], [5]])
            XCTAssertThrowsError(try NativeTextInput(text: "中文", mode: mode, method: "keys"))
            XCTAssertThrowsError(try NativeTextInput(text: "abc\t", mode: mode))
            XCTAssertThrowsError(try NativeTextInput(text: String(repeating: "a", count: 4097), mode: mode, method: "paste"))
        }
        for method in ["auto", "keys", "paste"] {
            let plan = try NativeTextInput(text: "", mode: "replace", method: method)
            guard case .clear = plan else { return XCTFail("Expected no-clipboard deletion") }
            XCTAssertFalse(plan.usesPasteboard)
            for mode in ["insert", "append"] { XCTAssertThrowsError(try NativeTextInput(text: "", mode: mode, method: method)) }
        }
        XCTAssertThrowsError(try NativeTextInput(text: "", mode: "replace", method: "invalid"))
    }

    func testAppendIsNativeScreenOnlyAndAllModesKeepObservationGuard() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory), context = screenTestContext()
        _ = try cache.store(CapturedObservation(nodes: [], metadata: ["backend": "apple-native",
            "screenContext": try jsonObject(JSONEncoder().encode(context))], screenshot: try screenPNG()))
        for mode in ["insert", "replace", "append"] {
            let request: [String: Any] = ["reference": "o1", "mode": mode, "text": "abc", "fieldRect": "18,146,354,36"]
            let action = try DeviceAction(operation: "type", request: request, allowScreenText: true)
            XCTAssertEqual(action.fields["mode"] as? String, mode)
            let guardValue = try XCTUnwrap(cache.resolveTarget(for: action).textGuard)
            XCTAssertEqual(guardValue.policy.maxRegionChange, 0)
            let changed = try screenPNG(patches: [(CGRect(x: 50, y: 160, width: 4, height: 10), [0,0,0])])
            XCTAssertFalse(try guardValue.check(png: changed, context: context).accepted)
        }
        for native in [false, true] {
            XCTAssertThrowsError(try DeviceAction(operation: "type", request: ["reference": "o1:e1", "mode": "append", "text": "abc"], allowScreenText: native))
        }
        XCTAssertThrowsError(try DeviceAction(operation: "type", request: ["reference": "o1", "mode": "append", "text": ""], allowScreenText: true))
    }

    func testRotationChangeRejectsIdenticalPixelsWithoutRetryAndPreservesNewFrame() throws {
        let screen = ScreenRect(CGRect(x: 0, y: 0, width: 844, height: 390))
        let context = ScreenContext(screen: screen, scope: screen, orientation: 4, keyboardCount: 0)
        let png = try screenPNG(width: 844, height: 390)
        let guardValue = try ScreenGuard(png: png, context: context, rects: [screen], policy: .init())
        // Left and right landscape have identical sizes. Orientation, not image
        // similarity, must stop a stale action even on a uniform screen.
        for (rotation, native, orientation) in [("rot270", "rot0", 3), ("rot90", "rot90", 4), ("rot90", "rot0", 3)] {
            var calls = 0
            XCTAssertThrowsError(try NativeInputPreflight.check(guard: guardValue, displayID: 1, displayRotation: "rot90",
                deadline: 8, maximumCaptures: 3, now: { 0 }) {
                calls += 1
                let changed = ScreenContext(screen: screen, scope: screen, orientation: orientation, keyboardCount: 0)
                return CapturedObservation(nodes: [], metadata: ["displayID": UInt64(1), "displayRotation": rotation,
                    "nativeRotation": native, "screenContext": try jsonObject(JSONEncoder().encode(changed))], screenshot: png)
            }) {
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
        let changed = try screenPNG(patches: [(CGRect(x: 50, y: 160, width: 4, height: 10), [0,0,0])])
        let guardValue = try ScreenGuard(png: baseline, context: context,
            rects: [ScreenRect(CGRect(x: 18, y: 146, width: 354, height: 36))], policy: .init())
        let metadata: [String: Any] = ["displayID": UInt64(1), "screenContext": try jsonObject(JSONEncoder().encode(context))]
        var count = 0
        let result = try NativeInputPreflight.check(guard: guardValue, displayID: 1, deadline: 8, maximumCaptures: 3, now: { Double(count) }) {
            count += 1
            return CapturedObservation(nodes: [], metadata: metadata, screenshot: count == 3 ? baseline : changed)
        }
        XCTAssertEqual(result.1, 3)
        XCTAssertEqual(result.0.regionChanges, [0])
        count = 0
        XCTAssertThrowsError(try NativeInputPreflight.check(guard: guardValue, displayID: 1, deadline: 8, maximumCaptures: 3, now: { Double(count) }) {
            count += 1
            return CapturedObservation(nodes: [], metadata: metadata, screenshot: changed)
        }) {
            XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, false)
            XCTAssertEqual(($0 as? ActionFailure)?.rejectedCapture?.screenshot, changed)
        }
        XCTAssertEqual(count, 3)
        // Identical changed frames never establish a new baseline.
    }

    func testPreflightTracePreservesEachComparisonWithoutChangingBaseline() throws {
        let context = screenTestContext(), baseline = try screenPNG()
        let changed = try screenPNG(patches: [(CGRect(x: 50, y: 160, width: 4, height: 10), [0,0,0])])
        let guardValue = try ScreenGuard(png: baseline, context: context,
            rects: [ScreenRect(CGRect(x: 18, y: 146, width: 354, height: 36))], policy: .init())
        let metadata: [String: Any] = ["displayID": UInt64(1), "screenContext": try jsonObject(JSONEncoder().encode(context))]
        for restoresBaseline in [false, true] {
            var time = 0.0, captures = 0, records: [[String: Any]] = []
            func run() throws -> (ScreenGuard.Check, Int) {
                try NativeInputPreflight.check(guard: guardValue, displayID: 1, deadline: 8, maximumCaptures: 3,
                    now: { time }, record: { records.append($0) }) {
                    captures += 1; time += 1
                    return CapturedObservation(nodes: [], metadata: metadata,
                        screenshot: restoresBaseline && captures == 3 ? baseline : changed)
                }
            }
            if restoresBaseline { XCTAssertTrue(try run().0.accepted) }
            else { XCTAssertThrowsError(try run()) { XCTAssertFalse(($0 as! ActionFailure).possiblyExecuted) } }
            XCTAssertEqual(captures, 3)
            XCTAssertEqual(records.compactMap { $0["attempt"] as? Int }, [1, 2, 3])
            XCTAssertEqual(records.compactMap { $0["elapsedMs"] as? Double }, [1000, 2000, 3000])
            XCTAssertEqual(records.compactMap { $0["captureAndCheckMs"] as? Double }, [1000, 1000, 1000])
            XCTAssertEqual(records.compactMap { ($0["screenGuard"] as? [String: Any])?["accepted"] as? Bool }, [false, false, restoresBaseline])
            XCTAssertTrue(records.allSatisfy { $0["inTime"] as? Bool == true })
        }
    }

    func testPreflightTraceRecordsLateMatchButNeverAuthorizesIt() throws {
        let context = screenTestContext(), baseline = try screenPNG()
        let guardValue = try ScreenGuard(png: baseline, context: context, rects: [context.screen], policy: .init())
        var time = 0.0, records: [[String: Any]] = []
        XCTAssertThrowsError(try NativeInputPreflight.check(guard: guardValue, displayID: 1,
            deadline: 8, maximumCaptures: 3, now: { time }, record: { records.append($0) }) {
                time = 9
                return CapturedObservation(nodes: [], metadata: ["displayID": UInt64(1),
                    "screenContext": try jsonObject(JSONEncoder().encode(context))], screenshot: baseline)
            }) { XCTAssertFalse(($0 as! ActionFailure).possiblyExecuted) }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["inTime"] as? Bool, false)
        XCTAssertEqual((records[0]["screenGuard"] as? [String: Any])?["accepted"] as? Bool, true)
    }

    func testLateMatchingFrameAndCancellationCannotAuthorizeInput() throws {
        let context = screenTestContext(), png = try screenPNG()
        let guardValue = try ScreenGuard(png: png, context: context, rects: [context.screen], policy: .init())
        let frame = CapturedObservation(nodes: [], metadata: ["displayID": UInt64(1), "screenContext": try jsonObject(JSONEncoder().encode(context))], screenshot: png)
        var time = 0.0, captures = 0
        XCTAssertThrowsError(try NativeInputPreflight.check(guard: guardValue, displayID: 1, deadline: 8, maximumCaptures: 3, now: { time }) {
            captures += 1; time = 9; return frame
        }) { XCTAssertEqual(($0 as? ActionFailure)?.result?["preInputDeadlineExceeded"] as? Bool, true) }
        XCTAssertEqual(captures, 1)
        let cancellation = NativeCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try NativeInputPreflight.check(guard: guardValue, displayID: 1, deadline: 8, maximumCaptures: 3, now: { 0 }) {
            try cancellation.check(); captures += 1; return frame
        })
        XCTAssertEqual(captures, 1)
    }
}
