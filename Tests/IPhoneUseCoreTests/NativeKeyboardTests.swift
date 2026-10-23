import XCTest
import AppleNativeBridge
@testable import IPhoneUseCore

func builtInKeyboard(id: Any = UInt64(761)) -> [String: Any] {
    [
        "_ServiceID": id, "PrimaryUsagePage": 0, "PrimaryUsage": 0,
        "DeviceTypeHint": "Keyboard", "Product": "CoreDevice keyboard",
        "_CoreDevice_codablePropertyStorage": [
            "Transport": ["string": "CoreDevice"],
            "_CoreDevice_originalUsages": [
                "array": [
                    [
                        "dictionary": [
                            "DeviceUsagePage": ["int": 1], "DeviceUsage": ["int": 6]
                        ]
                    ]
                ]
            ]
        ]
    ]
}

final class KeyboardTransport: NativeTransport {
    var services: [[String: Any]] = [
        ["_ServiceID": 987, "PrimaryUsagePage": 13, "PrimaryUsage": 4, "UniversalControlBuiltIn": true],
        builtInKeyboard()
    ]
    var reports: [Data] = []
    var removals: [UInt64] = []
    var destinations: [UInt64] = []
    var unexpectedRequests = 0
    var failSend = false
    var onSend: (() -> Void)?
    func request(_ message: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        let payload = (try XCTUnwrap(message["payload"] as? [String: Any]))
        if payload["connectedServices"] != nil { return ["connectedServices": services] }
        unexpectedRequests += 1
        throw IPhoneUseError("test_request", "Unexpected request")
    }
    func send(_ message: [String: Any], timeout: TimeInterval) throws {
        let payload = (try XCTUnwrap(message["payload"] as? [String: Any]))
        if let remove = payload["removeService"] as? [String: Any] {
            let id = ((try XCTUnwrap(remove["_0"] as? ASNativeUnsigned))).value
            removals.append(id); services.removeAll { ($0["_ServiceID"] as? NSNumber)?.uint64Value == id }
            return
        }
        let send = (try XCTUnwrap(payload["send"] as? [String: Any]))
        destinations.append(((try XCTUnwrap(send["_1"] as? ASNativeUnsigned))).value)
        reports.append((try XCTUnwrap(send["_0"] as? Data)))
        if failSend { throw TransportError(description: "Keyboard connection lost", possiblySent: true) }
        onSend?()
    }
    func cancel() {}
}

final class NativeKeyboardTests: XCTestCase {
}
