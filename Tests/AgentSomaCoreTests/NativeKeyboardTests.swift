import XCTest
import AppleNativeBridge
@testable import AgentSomaCore

private final class KeyboardTransport: NativeTransport {
    var services: [[String: Any]] = [["_ServiceID": 987, "PrimaryUsagePage": 13, "PrimaryUsage": 4, "UniversalControlBuiltIn": true]]
    var reports: [Data] = []
    var removals: [UInt64] = []
    var failCreationReply = false
    var failSend = false
    var onSend: (() -> Void)?
    func request(_ message: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        let payload = message["payload"] as! [String: Any]
        if payload["connectedServices"] != nil { return ["connectedServices": services] }
        if let create = payload["createService"] as? [String: Any], let properties = create["_0"] as? [String: Any] {
            let id = (properties["_ServiceID"] as! ASNativeUnsigned).value
            services.append(["_ServiceID": id, "Product": "CD-" + (properties["Product"] as! String)])
            if failCreationReply { throw TransportError(description: "Lost creation reply", possiblySent: true) }
            return ["serviceID": id]
        }
        throw SomaError("test_request", "Unexpected request")
    }
    func send(_ message: [String: Any], timeout: TimeInterval) throws {
        let payload = message["payload"] as! [String: Any]
        if let remove = payload["removeService"] as? [String: Any] {
            let id = (remove["_0"] as! ASNativeUnsigned).value
            removals.append(id); services.removeAll { ($0["_ServiceID"] as? NSNumber)?.uint64Value == id }
            return
        }
        reports.append((payload["send"] as! [String: Any])["_0"] as! Data)
        if failSend { throw TransportError(description: "Keyboard connection lost", possiblySent: true) }
        onSend?()
    }
    func cancel() {}
}

final class NativeKeyboardTests: XCTestCase {
    func testExplicitPreparationIsIdempotentAndReturnSendsOnlyKeyAndRelease() throws {
        let transport = KeyboardTransport()
        let keyboard = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation(), wait: { _ in })
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
        XCTAssertEqual(transport.removals.count, 1)
    }

    func testNativeReturnProtectsCurrentCompleteFieldAndRejectsRunnerScreenReference() throws {
        let request: [String: Any] = ["reference": "o1", "key": "return", "fieldRect": "18,146,354,36"]
        XCTAssertThrowsError(try DeviceAction(operation: "press", request: request))
        var invalid = request; invalid["key"] = "unknown"
        XCTAssertThrowsError(try DeviceAction(operation: "press", request: invalid, allowScreenText: true))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory), context = screenTestContext()
        let capture = CapturedObservation(nodes: [], metadata: ["backend": "apple-native",
            "screenContext": try jsonObject(JSONEncoder().encode(context))], screenshot: try screenPNG())
        _ = try cache.store(capture)
        let action = try DeviceAction(operation: "press", request: request, allowScreenText: true)
        let guardValue = try XCTUnwrap(cache.resolveTarget(for: action).textGuard)
        XCTAssertEqual(guardValue.regions.map(\.rect), [action.textRegion!])
        let changed = try screenPNG(patches: [(CGRect(x: 50, y: 160, width: 4, height: 10), [0,0,0])])
        XCTAssertFalse(try guardValue.check(png: changed, context: context).accepted)
        _ = try cache.store(capture)
        XCTAssertThrowsError(try cache.resolveTarget(for: action))
    }
    func testNativeEditingKeysSendOnePressWithModifierFirstAndRelease() throws {
        let cases: [(NativePressKey, [[UInt8]])] = [
            (.backspace, [[42], []]), (.left, [[80], []]), (.right, [[79], []]),
            (.up, [[82], []]), (.down, [[81], []]), (.tab, [[43], []]),
            (.shiftTab, [[225], [43, 225], []]), (.escape, [[41], []])]
        for (key, expected) in cases {
            let transport = KeyboardTransport(); var now = 0.0
            let hid = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
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
            let hid = NativeHIDAdapter(transport: transport, cancellation: cancellation, wait: { now += $0 }, uptime: { now })
            try hid.prepare(); try hid.prepareKeyboard()
            transport.onSend = { if transport.reports.count == cancelAfter { cancellation.cancel() } }
            XCTAssertThrowsError(try hid.press(.shiftTab)) {
                let failure = $0 as? ActionFailure
                XCTAssertEqual(failure?.possiblyExecuted, true)
                XCTAssertEqual(failure?.result?["key"] as? String, "shift-tab")
                XCTAssertEqual(failure?.result?["keyReportQueued"] as? String, "unknown")
                XCTAssertNil(failure?.result?["charactersQueued"])
                XCTAssertEqual((failure?.result?["cleanup"] as? [String: Any])?["keyboardReleaseQueued"] as? Bool, true)
            }
            XCTAssertTrue(try XCTUnwrap(transport.reports.last)[1...30].allSatisfy { $0 == 0 })
            let count = transport.reports.count
            XCTAssertThrowsError(try hid.press(.shiftTab)); XCTAssertEqual(transport.reports.count, count)
        }
    }

    func testEditingKeysRequireNativeScreenReferenceAndExactSupportedName() throws {
        for key in NativePressKey.allCases {
            let request: [String: Any] = ["reference": "o1", "key": key.rawValue]
            XCTAssertEqual(try DeviceAction(operation: "press", request: request, allowScreenText: true).fields["key"] as? String, key.rawValue)
            XCTAssertThrowsError(try DeviceAction(operation: "press", request: request))
            if key != .returnKey {
                for native in [false, true] {
                    XCTAssertThrowsError(try DeviceAction(operation: "press", request: ["reference": "o1:e2", "key": key.rawValue], allowScreenText: native))
                }
            }
        }
        for value: Any in ["Backspace", "shift+tab", "delete", "a", "", 42, true] {
            XCTAssertThrowsError(try DeviceAction(operation: "press", request: ["reference": "o1", "key": value], allowScreenText: true))
        }
    }

    func testLandscapeTextAndKeysRetainCompleteFieldGuardAndStaleReferenceRejection() throws {
        for (rotation, orientation) in [("rot90", 4), ("rot270", 3)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let screen = ScreenRect(CGRect(x: 0, y: 0, width: 844, height: 390))
            let context = ScreenContext(screen: screen, scope: screen, orientation: orientation, keyboardCount: 0)
            let capture = CapturedObservation(nodes: [], metadata: ["backend": "apple-native", "displayID": UInt64(1),
                "displayRotation": rotation, "nativeRotation": "rot0", "screenContext": try jsonObject(JSONEncoder().encode(context))],
                screenshot: try screenPNG(width: 844, height: 390))
            for operation in ["press", "type"] {
                let cache = ObservationCache(directory: directory); _ = try cache.store(capture)
                let action = try DeviceAction(operation: operation, request: ["reference": "o1", "key": "left",
                    "mode": "replace", "text": "横屏中文🙂", "fieldRect": "60,78,724,82"], allowScreenText: true)
                let guardValue = try XCTUnwrap(cache.resolveTarget(for: action).textGuard)
                XCTAssertEqual(guardValue.regions.map(\.rect), [action.textRegion!])
                let check = try NativeInputPreflight.check(guard: guardValue, displayID: 1, displayRotation: rotation,
                    deadline: 8, maximumCaptures: 1, now: { 0 }) { capture }
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
            let hid = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
            try hid.prepare(); try hid.prepareKeyboard()
            let result = try hid.paste(mode: mode)
            let expected: [[UInt8]] = [[0xe3], [0xe3, usage], [], [0xe3], [0xe3, 0x19], []]
            XCTAssertEqual(transport.reports.map { Array($0.prefix(31)) }, expected.map { Array(NativeKeyboard.report($0, timestamp: 0).prefix(31)) })
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
        let hid = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
        try hid.prepare(); try hid.prepareKeyboard()
        let result = try hid.clearText()
        let expected: [[UInt8]] = [[0xe3], [0xe3, 0x04], [], [0x2a], []]
        XCTAssertEqual(transport.reports.map { Array($0.prefix(31)) }, expected.map { Array(NativeKeyboard.report($0, timestamp: 0).prefix(31)) })
        XCTAssertNil(result["charactersQueued"])
        XCTAssertNil(result["pasteShortcutQueued"])
        XCTAssertEqual(result["deleteShortcutQueued"] as? Bool, true)
        XCTAssertEqual(try hid.type([[4], [5]], mode: "append")["charactersQueued"] as? Int, 2)
        let count = transport.reports.count
        XCTAssertThrowsError(try hid.type([[4]], mode: "invalid"))
        XCTAssertEqual(transport.reports.count, count)
    }

    func testCancellationDuringOrAfterEditingPrefixIsUnknownWithoutPayloadOrReplay() throws {
        for reportCount in [1, 2, 3] {
            for mode in ["replace", "append"] {
                let transport = KeyboardTransport(), cancellation = NativeCancellation()
                var now = 0.0
                let hid = NativeHIDAdapter(transport: transport, cancellation: cancellation, wait: { now += $0 }, uptime: { now })
                try hid.prepare(); try hid.prepareKeyboard()
                transport.onSend = { if transport.reports.count == reportCount { cancellation.cancel() } }
                XCTAssertThrowsError(try hid.paste(mode: mode)) {
                    let failure = $0 as? ActionFailure
                    XCTAssertEqual(failure?.possiblyExecuted, true)
                    XCTAssertEqual(failure?.result?["editingShortcutAttempted"] as? Bool, true)
                    XCTAssertEqual(failure?.result?["editingShortcutQueued"] as? Bool, reportCount == 3)
                    let cleanup = failure?.result?["cleanup"] as? [String: Any]
                    XCTAssertEqual(cleanup?["keyboardReleaseRequired"] as? Bool, reportCount != 3)
                    if reportCount != 3 { XCTAssertEqual(cleanup?["keyboardReleaseQueued"] as? Bool, true) }
                }
                XCTAssertTrue(try XCTUnwrap(transport.reports.last)[1..<31].allSatisfy { $0 == 0 })
                XCTAssertFalse(transport.reports.contains { ($0[4] & 2) != 0 }) // V never queued.
                let count = transport.reports.count
                XCTAssertThrowsError(try hid.paste(mode: mode))
                XCTAssertEqual(transport.reports.count, count)
            }
        }
    }

    func testPasteQueuesOneModifierChordAndReleaseWithoutClaimingCommittedCharacters() throws {
        let transport = KeyboardTransport()
        var now = 0.0
        let hid = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
        try hid.prepare(); try hid.prepareKeyboard()
        let result = try hid.paste()
        XCTAssertEqual(transport.reports.count, 3)
        XCTAssertEqual(transport.reports[0][29], 8) // GUI only.
        XCTAssertEqual(transport.reports[0][4], 0)
        XCTAssertEqual(transport.reports[1][4], 2) // V plus GUI.
        XCTAssertTrue(transport.reports[2][1..<31].allSatisfy { $0 == 0 })
        XCTAssertNil(result["charactersQueued"])
        XCTAssertEqual(result["pasteShortcutQueued"] as? Bool, true)
        XCTAssertEqual(result["textCommitConfirmed"] as? Bool, false)
    }
    func testCancelledPasteReleasesCommandAndCannotReplay() throws {
        let transport = KeyboardTransport(), cancellation = NativeCancellation()
        var now = 0.0
        let hid = NativeHIDAdapter(transport: transport, cancellation: cancellation, wait: { now += $0; cancellation.cancel() }, uptime: { now })
        try hid.prepare(); try hid.prepareKeyboard()
        XCTAssertThrowsError(try hid.paste()) {
            XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true)
            XCTAssertNil(($0 as? ActionFailure)?.result?["charactersQueued"])
        }
        XCTAssertEqual(transport.reports.count, 2)
        XCTAssertTrue(transport.reports[1][1..<31].allSatisfy { $0 == 0 })
        XCTAssertThrowsError(try hid.paste())
        XCTAssertEqual(transport.reports.count, 2)
    }
    func testASCIIValidationIsAtomicAndUSMappingIncludesModifiersAndPunctuation() throws {
        XCTAssertEqual(try NativeKeyboard.keys(for: "aZ0!? ", mode: "insert"), [[4], [225,29], [39], [225,30], [225,56], [44]])
        for byte in UInt8(32)...126 { XCTAssertFalse(try NativeKeyboard.keys(for: String(UnicodeScalar(byte)), mode: "insert").isEmpty) }
        for text in ["", "a北京", "abc\n", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try NativeKeyboard.keys(for: text, mode: "insert"))
        }
        XCTAssertThrowsError(try NativeKeyboard.keys(for: "a", mode: "replace"))
        let report = NativeKeyboard.report([4,225], timestamp: 0x010203040506)
        XCTAssertEqual(report.count, 39); XCTAssertEqual(report[0], 1)
        XCTAssertEqual(report[1], 16); XCTAssertEqual(report[29], 2)
        XCTAssertEqual(Array(report[31..<37]), [6,5,4,3,2,1])
        XCTAssertTrue(NativeKeyboard.report([], timestamp: 1)[1..<31].allSatisfy { $0 == 0 })
        let properties = NativeKeyboard.properties(id: 123, product: "AgentSoma test")
        XCTAssertEqual(properties["VendorID"] as? Int, 0)
        let storage = properties["_CoreDevice_codablePropertyStorage"] as! [String: Any]
        XCTAssertEqual((storage["Manufacturer"] as? [String: String])?["string"], "AgentSoma")
    }
    func testTypingQueuesKeyThenEmptySetAndRemovesOnlyOwnedKeyboard() throws {
        let transport = KeyboardTransport()
        transport.services.append(["_ServiceID": UInt64(555), "Product": "Other client's keyboard"])
        var now = 0.0
        let hid = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
        try hid.prepare(); try hid.prepareKeyboard()
        let result = try hid.type(NativeKeyboard.keys(for: "aZ!", mode: "insert"))
        XCTAssertEqual(result["charactersQueued"] as? Int, 3)
        XCTAssertEqual(result["focusConfirmed"] as? Bool, false)
        XCTAssertEqual(transport.reports.count, 8)
        for index in [1,4,7] { XCTAssertTrue(transport.reports[index][1..<31].allSatisfy { $0 == 0 }) }
        XCTAssertEqual(transport.reports[2][29], 2)
        XCTAssertEqual(transport.reports[2][4], 0) // Modifier-only precedes Z.
        XCTAssertEqual(transport.reports[3][4], 32)
        XCTAssertEqual(hid.closeKeyboard()["keyboardRemoveAcknowledged"] as? Bool, true)
        _ = hid.closeKeyboard()
        XCTAssertEqual(transport.removals.count, 1)
        XCTAssertEqual(transport.services.count, 2)
        XCTAssertTrue(transport.services.contains { ($0["_ServiceID"] as? NSNumber)?.intValue == 555 })
    }
    func testCancelAfterModifierKeyReleasesAndDoesNotContinueText() throws {
        let transport = KeyboardTransport(), cancellation = NativeCancellation()
        var now = 0.0
        let hid = NativeHIDAdapter(transport: transport, cancellation: cancellation, wait: { now += $0; cancellation.cancel() }, uptime: { now })
        try hid.prepare(); try hid.prepareKeyboard()
        XCTAssertThrowsError(try hid.type(NativeKeyboard.keys(for: "ABC", mode: "insert"))) {
            let failure = $0 as? ActionFailure
            XCTAssertEqual(failure?.possiblyExecuted, true)
            let cleanup = failure?.result?["cleanup"] as? [String: Any]
            XCTAssertEqual(cleanup?["keyboardReleaseQueued"] as? Bool, true)
        }
        XCTAssertEqual(transport.reports.count, 2)
        XCTAssertEqual(transport.reports[0][29], 2)
        XCTAssertTrue(transport.reports[1][1..<31].allSatisfy { $0 == 0 })
        XCTAssertEqual(hid.state, .inputUncertain)
        XCTAssertThrowsError(try hid.type([[4]]))
        XCTAssertEqual(transport.reports.count, 2)
    }
    func testLostKeySendAndReleaseStayUncertainAndOwnershipMismatchIsNotRemoved() throws {
        let transport = KeyboardTransport()
        let hid = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation())
        try hid.prepare(); try hid.prepareKeyboard()
        transport.failSend = true
        XCTAssertThrowsError(try hid.type([[4]])) {
            XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true)
        }
        XCTAssertEqual(transport.reports.count, 2)
        XCTAssertEqual(hid.state, .releaseUncertain)
        transport.services[1]["Product"] = "Foreign identity"
        XCTAssertEqual(hid.closeKeyboard()["keyboardRemoveAcknowledged"] as? Bool, false)
        XCTAssertTrue(transport.removals.isEmpty)
    }
    func testLostCreationReplyDoesNotSendKeysOrCreateAgainAndCleansOnlyMatchingIdentity() throws {
        let transport = KeyboardTransport()
        transport.failCreationReply = true
        let hid = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation())
        try hid.prepare()
        XCTAssertThrowsError(try hid.prepareKeyboard()) {
            XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, false)
        }
        XCTAssertFalse(hid.canType)
        XCTAssertTrue(transport.reports.isEmpty)
        XCTAssertThrowsError(try hid.prepareKeyboard())
        XCTAssertEqual(transport.services.count, 2)
        XCTAssertEqual(hid.closeKeyboard()["keyboardRemoveAcknowledged"] as? Bool, true)
        XCTAssertEqual(transport.removals.count, 1)
    }
    func testExplicitNativeFieldRegionKeepsStrictLocalAndGlobalProtection() throws {
        let request: [String: Any] = ["reference": "o1", "mode": "insert", "text": "zhongwen", "fieldRect": "18,146,354,36"]
        XCTAssertThrowsError(try DeviceAction(operation: "type", request: request))
        for rect in ["", "1,2,3", "1,2,3,4,5", "nan,2,3,4", "0,0,-1,2", "0,0,2,0"] {
            var invalid = request; invalid["fieldRect"] = rect
            XCTAssertThrowsError(try DeviceAction(operation: "type", request: invalid, allowScreenText: true))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory), context = screenTestContext()
        _ = try cache.store(CapturedObservation(nodes: [], metadata: ["backend": "apple-native",
            "screenContext": try jsonObject(JSONEncoder().encode(context))], screenshot: try screenPNG()))
        let action = try DeviceAction(operation: "type", request: request, allowScreenText: true)
        let guardValue = try XCTUnwrap(cache.resolveTarget(for: action).textGuard)
        XCTAssertEqual(guardValue.policy.maxRegionChange, 0)
        XCTAssertEqual(guardValue.policy.maxScreenChange, 0.01)
        let statusChange = try screenPNG(patches: [(CGRect(x: 20, y: 10, width: 6, height: 8), [0,0,0])])
        XCTAssertTrue(try guardValue.check(png: statusChange, context: context).accepted)
        let fieldChange = try screenPNG(patches: [(CGRect(x: 50, y: 160, width: 4, height: 10), [0,0,0])])
        XCTAssertFalse(try guardValue.check(png: fieldChange, context: context).accepted)
        let largeChange = try screenPNG(patches: [(CGRect(x: 0, y: 600, width: 390, height: 200), [0,0,0])])
        XCTAssertFalse(try guardValue.check(png: largeChange, context: context).accepted)
        var outside = request; outside["fieldRect"] = "380,146,354,36"
        XCTAssertThrowsError(try cache.resolveTarget(for: DeviceAction(operation: "type", request: outside, allowScreenText: true)))
    }

    func testNativeScreenTypingRequiresCurrentObservationAndProtectsWholeScreen() throws {
        let request: [String: Any] = ["reference": "o1", "mode": "insert", "text": "hello"]
        XCTAssertThrowsError(try DeviceAction(operation: "type", request: request))
        let action = try DeviceAction(operation: "type", request: request, allowScreenText: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory), context = screenTestContext()
        let capture = CapturedObservation(nodes: [], metadata: ["backend": "apple-native",
            "screenContext": try jsonObject(JSONEncoder().encode(context))], screenshot: try screenPNG())
        _ = try cache.store(capture)
        let target = try cache.resolveTarget(for: action)
        XCTAssertEqual(target.textGuard?.regions.map(\.rect), [context.screen])
        _ = try cache.store(capture)
        XCTAssertThrowsError(try cache.resolveTarget(for: action))
    }
}
