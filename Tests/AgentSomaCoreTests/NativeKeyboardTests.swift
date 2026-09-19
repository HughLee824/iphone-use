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
