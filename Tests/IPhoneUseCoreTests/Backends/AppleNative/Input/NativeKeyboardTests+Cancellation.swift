import XCTest
import AppleNativeBridge
@testable import IPhoneUseCore

extension NativeKeyboardTests {

    func testCancellationDuringOrAfterEditingPrefixIsUnknownWithoutPayloadOrReplay() throws {
        for reportCount in [1, 2, 3] {
            for mode in ["replace", "append"] {
                let transport = KeyboardTransport(), cancellation = NativeCancellation()
                var now = 0.0
                let hid = NativeHIDAdapter(
                    transport: transport, cancellation: cancellation, wait: { now += $0 }, uptime: { now })
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
        let hid = NativeHIDAdapter(
            transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
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
        let hid = NativeHIDAdapter(
            transport: transport, cancellation: cancellation,
            wait: {
                now += $0; cancellation.cancel()
            }, uptime: { now })
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
        XCTAssertEqual(
            try NativeKeyboard.keys(for: "aZ0!? ", mode: "insert"),
            [[4], [225, 29], [39], [225, 30], [225, 56], [44]])
        for byte in UInt8(32)...126 {
            XCTAssertFalse(try NativeKeyboard.keys(for: String(UnicodeScalar(byte)), mode: "insert").isEmpty)
        }
        for text in ["", "a北京", "abc\n", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try NativeKeyboard.keys(for: text, mode: "insert"))
        }
        XCTAssertThrowsError(try NativeKeyboard.keys(for: "a", mode: "replace"))
        let report = NativeKeyboard.report([4, 225], timestamp: 0x010203040506)
        XCTAssertEqual(report.count, 39); XCTAssertEqual(report[0], 1)
        XCTAssertEqual(report[1], 16); XCTAssertEqual(report[29], 2)
        XCTAssertEqual(Array(report[31..<37]), [6, 5, 4, 3, 2, 1])
        XCTAssertTrue(NativeKeyboard.report([], timestamp: 1)[1..<31].allSatisfy { $0 == 0 })
    }
    func testTypingQueuesKeyThenEmptySetAndNeverRemovesBorrowedOrForeignKeyboard() throws {
        let transport = KeyboardTransport()
        transport.services.append(["_ServiceID": UInt64(555), "Product": "Other client's keyboard"])
        var now = 0.0
        let hid = NativeHIDAdapter(
            transport: transport, cancellation: NativeCancellation(), wait: { now += $0 }, uptime: { now })
        try hid.prepare(); try hid.prepareKeyboard()
        let result = try hid.type(NativeKeyboard.keys(for: "aZ!", mode: "insert"))
        XCTAssertEqual(result["charactersQueued"] as? Int, 3)
        XCTAssertEqual(result["focusConfirmed"] as? Bool, false)
        XCTAssertEqual(transport.reports.count, 8)
        for index in [1, 4, 7] { XCTAssertTrue(transport.reports[index][1..<31].allSatisfy { $0 == 0 }) }
        XCTAssertEqual(transport.reports[2][29], 2)
        XCTAssertEqual(transport.reports[2][4], 0) // Modifier-only precedes Z.
        XCTAssertEqual(transport.reports[3][4], 32)
        XCTAssertEqual(hid.closeKeyboard()["keyboardRemoveAcknowledged"] as? Bool, true)
        _ = hid.closeKeyboard()
        XCTAssertTrue(transport.removals.isEmpty)
        XCTAssertEqual(transport.unexpectedRequests, 0)
        XCTAssertTrue(transport.destinations.allSatisfy { $0 == 761 })
        XCTAssertEqual(transport.services.count, 3)
        XCTAssertTrue(transport.services.contains { ($0["_ServiceID"] as? NSNumber)?.intValue == 555 })
    }
    func testCancelAfterModifierKeyReleasesAndDoesNotContinueText() throws {
        let transport = KeyboardTransport(), cancellation = NativeCancellation()
        var now = 0.0
        let hid = NativeHIDAdapter(
            transport: transport, cancellation: cancellation,
            wait: {
                now += $0; cancellation.cancel()
            }, uptime: { now })
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
    func testLostKeySendAndReleaseStayUncertainAndBorrowedServiceIsNotRemoved() throws {
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
        XCTAssertEqual(hid.closeKeyboard()["keyboardRemovalRequired"] as? Bool, false)
        XCTAssertEqual(hid.state, .releaseUncertain)
        XCTAssertTrue(transport.removals.isEmpty)
    }
    func testMissingOrAmbiguousBuiltInKeyboardNeverCreatesServiceOrSendsKeys() throws {
        for candidates in [
            [], [builtInKeyboard(), builtInKeyboard(id: 762)],
            [builtInKeyboard(), ["_ServiceID": 761, "Product": "Foreign service"]]
        ] {
            let transport = KeyboardTransport()
            transport.services = [transport.services[0]] + candidates
            let hid = NativeHIDAdapter(transport: transport, cancellation: NativeCancellation())
            try hid.prepare()
            XCTAssertThrowsError(try hid.prepareKeyboard()) {
                XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, false)
            }
            XCTAssertThrowsError(try hid.type([[4]]))
            XCTAssertTrue(transport.reports.isEmpty)
            XCTAssertEqual(hid.closeKeyboard()["keyboardRemovalRequired"] as? Bool, false)
            XCTAssertTrue(transport.removals.isEmpty)
            XCTAssertEqual(transport.unexpectedRequests, 0)
        }
    }

    func testBuiltInSelectionRequiresNativeMetadataAndDynamicPositiveIdentifier() throws {
        for id: UInt64 in [761, 9821, UInt64(UInt32.max) + 99] {
            XCTAssertEqual(try NativeKeyboard.builtInService(in: [builtInKeyboard(id: id)]), id)
        }
        for invalid: Any in [0, -1, true, 1.25, "761", NSNull()] {
            XCTAssertThrowsError(try NativeKeyboard.builtInService(in: [builtInKeyboard(id: invalid)]))
        }
        for key in [
            "DeviceTypeHint", "Product", "PrimaryUsagePage", "PrimaryUsage",
            "_CoreDevice_codablePropertyStorage"
        ] {
            var service = builtInKeyboard(); service.removeValue(forKey: key)
            XCTAssertThrowsError(try NativeKeyboard.builtInService(in: [service]))
        }
        var service = builtInKeyboard()
        service["_CoreDevice_codablePropertyStorage"] = ["Transport": ["string": "Virtual"]]
        XCTAssertThrowsError(try NativeKeyboard.builtInService(in: [service]))
    }
}
