@testable import IPhoneUseRunnerSupport
import XCTest
import AppleNativeBridge
@testable import IPhoneUseCore

extension NativeKeyboardTests {
    func testExplicitPreparationIsIdempotentAndReturnSendsOnlyKeyAndRelease() throws {
        let transport = KeyboardTransport()
        let keyboard = NativeHIDAdapter(
            transport: transport, cancellation: NativeCancellation(), wait: { _ in })
        try keyboard.prepare(); try keyboard.prepareKeyboard(); try keyboard.prepareKeyboard()
        XCTAssertEqual(transport.services.count, 2)
        XCTAssertTrue(transport.reports.isEmpty)
        let result = try keyboard.press(.returnKey)
        XCTAssertEqual(transport.reports.count, 2)
        XCTAssertEqual(transport.reports[0][6], 1) // Usage 0x28: bit zero in byte 6.
        XCTAssertTrue(transport.reports[1][1...30].allSatisfy { $0 == 0 })
        XCTAssertEqual(result["keyReportQueued"] as? Bool, true)
        XCTAssertEqual(result["key"] as? String, "return")
        XCTAssertNil(result["charactersQueued"])
        XCTAssertEqual(keyboard.closeKeyboard()["keyboardRemoveAcknowledged"] as? Bool, true)
        XCTAssertTrue(transport.removals.isEmpty)
        XCTAssertEqual(transport.unexpectedRequests, 0)
        XCTAssertTrue(transport.destinations.allSatisfy { $0 == 761 })
    }

    func testNativeReturnProtectsCurrentCompleteFieldAndRejectsRunnerScreenReference() throws {
        let request: [String: Any] = ["reference": "o1", "key": "return", "fieldRect": "18,146,354,36"]
        XCTAssertThrowsError(try DeviceAction(operation: "press", request: request))
        var invalid = request; invalid["key"] = "unknown"
        XCTAssertThrowsError(try DeviceAction(operation: "press", request: invalid, allowScreenText: true))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory), context = screenTestContext()
        let capture = CapturedObservation(
            nodes: [],
            metadata: [
                "backend": "apple-native",
                "screenContext": try jsonObject(JSONEncoder().encode(context))
            ], screenshot: try screenPNG())
        _ = try cache.store(capture)
        let action = try DeviceAction(operation: "press", request: request, allowScreenText: true)
        let guardValue = try XCTUnwrap(cache.resolveTarget(for: action).textGuard)
        XCTAssertEqual(guardValue.regions.map(\.rect), [action.textRegion!])
        let changed = try screenPNG(patches: [(CGRect(x: 50, y: 160, width: 4, height: 10), [0, 0, 0])])
        XCTAssertFalse(try guardValue.check(png: changed, context: context).accepted)
        _ = try cache.store(capture)
        XCTAssertThrowsError(try cache.resolveTarget(for: action))
    }
    func testNativeEditingKeysSendOnePressWithModifierFirstAndRelease() throws {
        let cases: [(NativePressKey, [[UInt8]])] = [
            (.backspace, [[42], []]), (.left, [[80], []]), (.right, [[79], []]),
            (.upArrow, [[82], []]), (.down, [[81], []]), (.tab, [[43], []]),
            (.shiftTab, [[225], [43, 225], []]), (.escape, [[41], []])
        ]
        for (key, expected) in cases {
            let transport = KeyboardTransport(); var now = 0.0
            let hid = NativeHIDAdapter(
                transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now }
            )
            try hid.prepare(); try hid.prepareKeyboard()
            let result = try hid.press(key)
            let usages = transport.reports.map { report in
                (0..<240).compactMap { usage -> UInt8? in
                    report[1 + usage / 8] & (1 << (usage % 8)) != 0 ? UInt8(usage) : nil
                }
            }
            XCTAssertEqual(usages, expected, key.rawValue)
            XCTAssertEqual(result["key"] as? String, key.rawValue)
            XCTAssertEqual(result["keyReportQueued"] as? Bool, true)
            XCTAssertEqual(result["keyEffectConfirmed"] as? Bool, false)
            XCTAssertNil(result["charactersQueued"])
            XCTAssertNil(result["textMode"])
        }
    }

    func testShiftTabCancellationReleasesModifierAndNeverReplays() throws {
        for cancelAfter in [1, 2] {
            let transport = KeyboardTransport(), cancellation = NativeCancellation(); var now = 0.0
            let hid = NativeHIDAdapter(
                transport: transport, cancellation: cancellation, wait: { now += $0 }, uptime: { now })
            try hid.prepare(); try hid.prepareKeyboard()
            transport.onSend = { if transport.reports.count == cancelAfter { cancellation.cancel() } }
            XCTAssertThrowsError(try hid.press(.shiftTab)) {
                let failure = $0 as? ActionFailure
                XCTAssertEqual(failure?.possiblyExecuted, true)
                XCTAssertEqual(failure?.result?["key"] as? String, "shift-tab")
                XCTAssertEqual(failure?.result?["keyReportQueued"] as? String, "unknown")
                XCTAssertNil(failure?.result?["charactersQueued"])
                XCTAssertEqual(
                    (failure?.result?["cleanup"] as? [String: Any])?["keyboardReleaseQueued"] as? Bool, true)
            }
            XCTAssertTrue(try XCTUnwrap(transport.reports.last)[1...30].allSatisfy { $0 == 0 })
            let count = transport.reports.count
            XCTAssertThrowsError(try hid.press(.shiftTab)); XCTAssertEqual(transport.reports.count, count)
        }
    }

    func testEditingKeysRequireNativeScreenReferenceAndExactSupportedName() throws {
        for key in NativePressKey.allCases {
            let request: [String: Any] = ["reference": "o1", "key": key.rawValue]
            XCTAssertEqual(
                try DeviceAction(operation: "press", request: request, allowScreenText: true).fields["key"]
                    as? String,
                key.rawValue)
            XCTAssertThrowsError(try DeviceAction(operation: "press", request: request))
            if key != .returnKey {
                for native in [false, true] {
                    if native {
                        XCTAssertThrowsError(
                            try DeviceAction(
                                operation: "press", request: ["reference": "o1:e2", "key": key.rawValue],
                                allowScreenText: true))
                    } else if key == .escape {
                        XCTAssertThrowsError(
                            try DeviceAction(
                                operation: "press", request: ["reference": "o1:e2", "key": key.rawValue]))
                    } else {
                        XCTAssertNoThrow(
                            try DeviceAction(
                                operation: "press", request: ["reference": "o1:e2", "key": key.rawValue]))
                    }
                }
            }
        }
        for value: Any in ["Backspace", "shift+tab", "delete", "a", "", 42, true] {
            XCTAssertThrowsError(
                try DeviceAction(
                    operation: "press", request: ["reference": "o1", "key": value], allowScreenText: true))
        }
    }

    func testLandscapeTextAndKeysRetainCompleteFieldGuardAndStaleReferenceRejection() throws {
        for (rotation, orientation) in [("rot90", 4), ("rot270", 3)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let screen = ScreenRect(CGRect(x: 0, y: 0, width: 844, height: 390))
            let context = ScreenContext(
                screen: screen, scope: screen, orientation: orientation, keyboardCount: 0)
            let capture = CapturedObservation(
                nodes: [],
                metadata: [
                    "backend": "apple-native", "displayID": UInt64(1),
                    "displayRotation": rotation, "nativeRotation": "rot0",
                    "screenContext": try jsonObject(JSONEncoder().encode(context))
                ],
                screenshot: try screenPNG(width: 844, height: 390))
            for operation in ["press", "type"] {
                let cache = ObservationCache(directory: directory); _ = try cache.store(capture)
                let action = try DeviceAction(
                    operation: operation,
                    request: [
                        "reference": "o1", "key": "left",
                        "mode": "replace", "text": "横屏中文🙂", "fieldRect": "60,78,724,82"
                    ], allowScreenText: true)
                let guardValue = try XCTUnwrap(cache.resolveTarget(for: action).textGuard)
                XCTAssertEqual(guardValue.regions.map(\.rect), [action.textRegion!])
                let check = try NativeInputPreflight.check(
                    guard: guardValue, displayID: 1, displayRotation: rotation,
                    deadline: 8, maximumCaptures: 1, now: { 0 }, capture: { capture })
                XCTAssertTrue(check.0.accepted)
                _ = try cache.store(capture)
                XCTAssertThrowsError(try cache.resolveTarget(for: action))
            }
        }
    }

    func testEditingPrefixReleasesBeforePasteAndDoesNotCountAsText() throws {
        for (mode, usage) in [("replace", UInt8(0x04)), ("append", UInt8(0x51))] {
            let transport = KeyboardTransport()
            var now = 0.0
            let hid = NativeHIDAdapter(
                transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now }
            )
            try hid.prepare(); try hid.prepareKeyboard()
            let result = try hid.paste(mode: mode)
            let expected: [[UInt8]] = [[0xe3], [0xe3, usage], [], [0xe3], [0xe3, 0x19], []]
            XCTAssertEqual(
                transport.reports.map { Array($0.prefix(31)) },
                expected.map { Array(NativeKeyboard.report($0, timestamp: 0).prefix(31)) })
            XCTAssertEqual(result["textMode"] as? String, mode)
            XCTAssertEqual(result["editingShortcutQueued"] as? Bool, true)
            XCTAssertEqual(result["editingEffectConfirmed"] as? Bool, false)
            XCTAssertNil(result["charactersQueued"])
            XCTAssertEqual(result["pasteShortcutQueued"] as? Bool, true)
        }
    }

    func testClearUsesSelectAllDeleteWithoutPasteAndKeysModeCountsPayloadOnly() throws {
        let transport = KeyboardTransport()
        var now = 0.0
        let hid = NativeHIDAdapter(
            transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
        try hid.prepare(); try hid.prepareKeyboard()
        let result = try hid.clearText()
        let expected: [[UInt8]] = [[0xe3], [0xe3, 0x04], [], [0x2a], []]
        XCTAssertEqual(
            transport.reports.map { Array($0.prefix(31)) },
            expected.map { Array(NativeKeyboard.report($0, timestamp: 0).prefix(31)) })
        XCTAssertNil(result["charactersQueued"])
        XCTAssertNil(result["pasteShortcutQueued"])
        XCTAssertEqual(result["deleteShortcutQueued"] as? Bool, true)
        XCTAssertEqual(try hid.type([[4], [5]], mode: "append")["charactersQueued"] as? Int, 2)
        let count = transport.reports.count
        XCTAssertThrowsError(try hid.type([[4]], mode: "invalid"))
        XCTAssertEqual(transport.reports.count, count)
    }
}
