import XCTest
@testable import IPhoneUseCore

extension NativeTextInputTests {
    func testOrientationRecoveryRequiresNewDecisionEvenWhenPixelsAndDirectionMatch() throws {
        let context = screenTestContext(), png = try screenPNG()
        let guardValue = try ScreenGuard(png: png, context: context, rects: [context.screen], policy: .init())
        var calls = 0
        XCTAssertThrowsError(
            try NativeInputPreflight.check(
                guard: guardValue, displayID: 1,
                deadline: 8, maximumCaptures: 3, now: { 0 },
                capture: {
                    calls += 1
                    return CapturedObservation(
                        nodes: [],
                        metadata: [
                            "displayID": UInt64(1), "orientationResynchronized": true,
                            "screenContext": try jsonObject(JSONEncoder().encode(context))
                        ], screenshot: png)
                })
        ) {
            let failure = $0 as? ActionFailure
            XCTAssertEqual(failure?.possiblyExecuted, false)
            XCTAssertEqual(failure?.result?["orientationResynchronized"] as? Bool, true)
            XCTAssertEqual(failure?.rejectedCapture?.screenshot, png)
        }
        XCTAssertEqual(calls, 1)
    }
    func testCaptureSourceChangeReturnsFreshObservationWithoutRetryOrInput() throws {
        let context = screenTestContext(), png = try screenPNG()
        let guardValue = try ScreenGuard(png: png, context: context, rects: [context.screen], policy: .init())
        var calls = 0
        XCTAssertThrowsError(
            try NativeInputPreflight.check(
                guard: guardValue, displayID: 1,
                captureSource: "native_media", deadline: 8, maximumCaptures: 3, now: { 0 },
                capture: {
                    calls += 1
                    return CapturedObservation(
                        nodes: [],
                        metadata: [
                            "displayID": UInt64(1), "captureSource": "coredevice_screenshot",
                            "screenContext": try jsonObject(JSONEncoder().encode(context))
                        ], screenshot: png)
                })
        ) {
            let failure = $0 as? ActionFailure
            XCTAssertEqual(failure?.possiblyExecuted, false)
            XCTAssertEqual(failure?.result?["captureSourceChanged"] as? Bool, true)
            XCTAssertEqual(failure?.rejectedCapture?.screenshot, png)
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(guardValue.policy.maxRegionChange, 0)
    }
    func testExplicitPasteAcceptsLongASCIIAndKeysNeverFallBackToClipboard() throws {
        let text = String(repeating: "Ab7 ?", count: 819) + "!"
        XCTAssertEqual(text.utf8.count, 4096)
        guard case .pasteboard(let payload) = try NativeTextInput(text: text, mode: "insert", method: "paste")
        else {
            return XCTFail("Expected literal paste")
        }
        XCTAssertEqual(payload, text)
        XCTAssertThrowsError(try NativeTextInput(text: text + "!", mode: "insert", method: "paste"))
        for method in ["keys", "auto"] {
            XCTAssertThrowsError(try NativeTextInput(text: text, mode: "insert", method: method))
        }
        XCTAssertThrowsError(try NativeTextInput(text: "中文", mode: "insert", method: "keys"))
        XCTAssertThrowsError(try NativeTextInput(text: "abc", mode: "insert", method: "invalid"))
        XCTAssertThrowsError(try NativeTextInput(text: "abc\t", mode: "insert", method: "paste"))
    }

    func testMultilinePastePreservesBytesAndNeverSynthesizesReturn() throws {
        for text in ["one\ntwo\n", "第一行🙂\n\n末行", "one\r\ntwo", "one\rtwo"] {
            for mode in ["insert", "replace", "append"] {
                for method in ["auto", "paste"] {
                    let action = try DeviceAction(
                        operation: "type",
                        request: [
                            "reference": "o1", "mode": mode,
                            "text": text, "textMethod": method
                        ], allowScreenText: true)
                    let payload = try XCTUnwrap(action.fields["text"] as? String)
                    guard
                        case .pasteboard(let value) = try NativeTextInput(
                            text: payload, mode: mode, method: method)
                    else {
                        return XCTFail("Line breaks must never generate keyboard Return reports")
                    }
                    XCTAssertEqual(Array(value.utf8), Array(text.utf8))
                }
                XCTAssertThrowsError(try NativeTextInput(text: text, mode: mode, method: "keys"))
                XCTAssertThrowsError(
                    try DeviceAction(
                        operation: "type",
                        request: [
                            "reference": "o1", "mode": mode,
                            "text": text, "textMethod": "keys"
                        ], allowScreenText: true))
            }
            XCTAssertNoThrow(
                try DeviceAction(
                    operation: "type", request: ["reference": "o1", "mode": "insert", "text": text],
                    allowScreenText: true))
            if text.unicodeScalars.contains(where: { $0.value == 13 }) {
                XCTAssertThrowsError(
                    try DeviceAction(
                        operation: "type", request: ["reference": "o1:e1", "mode": "insert", "text": text])
                )
            } else {
                XCTAssertNoThrow(
                    try DeviceAction(
                        operation: "type", request: ["reference": "o1:e1", "mode": "insert", "text": text])
                )
            }
        }
    }

    func testMultilinePasteRejectsControlsAndEnforcesByteLimit() throws {
        for text in ["a\n\u{0}", "a\n\t", "a\r\u{1b}", "a\n\u{7f}", "a\n\u{2028}"] {
            XCTAssertThrowsError(try NativeTextInput(text: text, mode: "insert", method: "paste"))
            XCTAssertThrowsError(
                try DeviceAction(
                    operation: "type", request: ["reference": "o1", "mode": "insert", "text": text],
                    allowScreenText: true))
        }
        let limit = String(repeating: "a", count: 4095) + "\n"
        guard case .pasteboard(let value) = try NativeTextInput(text: limit, mode: "insert") else {
            return XCTFail("Expected paste")
        }
        XCTAssertEqual(value.utf8.count, 4096)
        XCTAssertThrowsError(try NativeTextInput(text: limit + "a", mode: "insert"))
    }

    func testMethodSurvivesActionAndObservationResolutionAndRejectsRunner() throws {
        let request: [String: Any] = [
            "reference": "o1", "mode": "insert", "text": String(repeating: "a", count: 100),
            "textMethod": "paste"
        ]
        let action = try DeviceAction(operation: "type", request: request, allowScreenText: true)
        XCTAssertEqual(action.fields["textMethod"] as? String, "paste")
        XCTAssertThrowsError(try DeviceAction(operation: "type", request: request))
        XCTAssertThrowsError(try DeviceAction(operation: "tap", request: request, allowScreenText: true))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        let frame = CapturedObservation(
            nodes: [],
            metadata: [
                "backend": "apple-native",
                "screenContext": try jsonObject(JSONEncoder().encode(screenTestContext()))
            ], screenshot: try screenPNG())
        _ = try cache.store(frame)
        XCTAssertNotNil(try cache.resolveTarget(for: action).textGuard)
        XCTAssertEqual(
            try cache.resolveTextConfirmation(ObservationReference("o1"))["backend"] as? String,
            "apple-native")
        XCTAssertThrowsError(try cache.resolveTextConfirmation(ObservationReference("o1:e1")))
        _ = try cache.store(frame)
        XCTAssertThrowsError(try cache.resolveTextConfirmation(ObservationReference("o1")))
    }

    func testUnicodeResolvesThroughObservationCacheAndStillRequiresCurrentSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = screenTestContext(), cache = ObservationCache(directory: directory)
        let frame = CapturedObservation(
            nodes: [],
            metadata: [
                "backend": "apple-native",
                "screenContext": try jsonObject(JSONEncoder().encode(context))
            ], screenshot: try screenPNG())
        _ = try cache.store(frame)
        let action = try DeviceAction(
            operation: "type", request: ["reference": "o1", "mode": "insert", "text": "中文 A🙂"],
            allowScreenText: true)
        let target = try cache.resolveTarget(for: action)
        XCTAssertEqual(target.textGuard?.regions.map(\.rect), [context.screen])
        _ = try cache.store(frame)
        XCTAssertThrowsError(try cache.resolveTarget(for: action))
    }
    func testUnicodeIsOneWholePayloadAndExistingASCIIContractIsPreserved() throws {
        for text in ["中文", "中英 A7，🙂", "e\u{301}", "👩‍💻", String(repeating: "中", count: 1365)] {
            guard case .pasteboard(let value) = try NativeTextInput(text: text, mode: "insert") else {
                return XCTFail("Unicode must not be partially sent as keys")
            }
            XCTAssertEqual(Array(value.utf8), Array(text.utf8))
        }
        guard case .keyboard(let keys) = try NativeTextInput(text: "Ab7!?", mode: "insert") else {
            return XCTFail("ASCII changed")
        }
        XCTAssertEqual(keys, try NativeKeyboard.keys(for: "Ab7!?", mode: "insert"))
        for text in [
            "", "中\t文", "中\u{85}", "中\u{2028}", String(repeating: "中", count: 1366),
            String(repeating: "a", count: 65)
        ] {
            XCTAssertThrowsError(try NativeTextInput(text: text, mode: "insert"))
        }
        XCTAssertThrowsError(try NativeTextInput(text: "中文", mode: "unknown"))
    }
}
