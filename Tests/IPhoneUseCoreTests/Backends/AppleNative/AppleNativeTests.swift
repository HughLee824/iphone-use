@testable import IPhoneUseRunnerSupport
import XCTest
import CoreGraphics
import AppleNativeBridge
import Darwin
@testable import IPhoneUseCore

final class ReplyChannel: NativeChannel {
    let lock = NSLock()
    var callbacks: [Int: ([String: Any]?, Error?) -> Void] = [:]
    var submitted: ((Int) -> Void)?
    var cancellations = 0
    var onCancel: (() -> Void)?
    var sends = 0
    func request(_ message: [String: Any], completion: @escaping ([String: Any]?, Error?) -> Void) {
        guard let id = message["id"] as? Int else {
            XCTFail("Test message must contain an integer ID")
            completion(nil, IPhoneUseError("invalid_test_message", "Missing ID"))
            return
        }
        lock.lock(); callbacks[id] = completion; let notify = submitted; lock.unlock()
        notify?(id)
    }
    func reply(_ id: Int, value: Int) {
        lock.lock(); let callback = callbacks[id]; lock.unlock()
        callback?(["value": value], nil)
    }
    func send(_ message: [String: Any], completion: @escaping (Error?) -> Void) {
        sends += 1; completion(nil)
    }
    func cancel() { lock.lock(); cancellations += 1; lock.unlock(); onCancel?() }
}

final class ScriptedTransport: NativeTransport {
    var requests: [[String: Any]] = []
    var sends: [[String: Any]] = []
    var cancellations = 0
    var onRequest: (([String: Any]) throws -> [String: Any])?
    var onSend: (([String: Any]) throws -> Void)?
    func request(_ message: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        requests.append(message)
        return try onRequest?(message) ?? [
            "connectedServices": [
                [
                    "PrimaryUsagePage": 13, "PrimaryUsage": 4,
                    "UniversalControlBuiltIn": true, "_ServiceID": 987
                ]
            ]
        ]
    }
    func send(_ message: [String: Any], timeout: TimeInterval) throws {
        sends.append(message); try onSend?(message)
    }
    func cancel() { cancellations += 1 }
}

final class MediaReceiver: NativeMediaReceiver {
    let address = "::1"
    let port: UInt16 = 3456
    var closes = 0
    var configured = false
    func configure(_ configuration: [String: Any]) throws { configured = true }
    func health() -> [String: Any] { ["healthy": configured] }
    func close() { closes += 1 }
}

final class MediaTestClock {
    let lock = NSLock()
    var value = 10.0
    func read() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Double) { lock.lock(); self.value = value; lock.unlock() }
}

final class TouchChannel: NativeChannel {
    var reports: [Data] = []
    var cancellations = 0
    func request(_ message: [String: Any], completion: @escaping ([String: Any]?, Error?) -> Void) {
        completion(
            [
                "connectedServices": [
                    [
                        "PrimaryUsagePage": 13, "PrimaryUsage": 4,
                        "UniversalControlBuiltIn": true, "_ServiceID": 987
                    ]
                ]
            ], nil)
    }
    func send(_ message: [String: Any], completion: @escaping (Error?) -> Void) {
        guard let payload = message["payload"] as? [String: Any],
            let send = payload["send"] as? [String: Any], let data = send["_0"] as? Data
        else {
            XCTFail("Test send must contain report data")
            completion(IPhoneUseError("invalid_test_message", "Missing report data"))
            return
        }
        reports.append(data)
        completion(nil)
    }
    func cancel() { cancellations += 1 }
}

final class AppleNativeTests: XCTestCase {

    func reports(_ transport: ScriptedTransport) -> [Data] {
        transport.sends.compactMap {
            (($0["payload"] as? [String: Any])?["send"] as? [String: Any])?["_0"] as? Data
        }
    }

    func swipePlan(
        start: CGPoint = CGPoint(x: 195, y: 600), end: CGPoint = CGPoint(x: 195, y: 500),
        motion: SwipeMotion = SwipeMotion(), scale: Int = 3
    ) throws -> NativeSwipePlan {
        let context = screenTestContext()
        let guardValue = try ScreenGuard(
            png: screenPNG(width: 390 * scale, height: 844 * scale), context: context,
            rects: CoordinateGesture.actionRegions(start: start, end: end, screen: context.screen.cgRect),
            policy: .init())
        return try NativeSwipePlan(
            gesture: CoordinateGesture(start: start, end: end, screenGuard: guardValue, motion: motion))
    }
    func point(_ data: Data) -> [Int] { [Int(data[4]) | Int(data[5]) << 8, Int(data[6]) | Int(data[7]) << 8] }

    func mediaScript(_ transport: ScriptedTransport, sessions: [Any] = []) {
        var active = sessions
        transport.onRequest = { request in
            let feature = (try XCTUnwrap(request["CoreDevice.featureIdentifier"] as? String))
            // Actual iOS 27 status output is flat; serverInfo belongs to the stop reply.
            if feature.hasSuffix("getmediastreamserverstatus") {
                return ["CoreDevice.output": ["sessions": active, "running": !active.isEmpty]]
            }
            if feature.hasSuffix("startmediastream") {
                let input = (try XCTUnwrap(request["CoreDevice.input"] as? [String: Any]))
                let connection: [String: Any] = [
                    "options": input["options"]!, "streamConfig": ["RemoteSSRC": UInt32(123456)]
                ]
                active.append(["connection": connection])
                return ["CoreDevice.output": ["connection": connection, "negotiatorAnswer": Data([1])]]
            }
            if feature.hasSuffix("stopmediastream") { active = [] }
            return ["CoreDevice.output": [:]]
        }
    }
    func media(_ transport: ScriptedTransport, _ receiver: MediaReceiver) -> NativeMediaSession {
        NativeMediaSession(
            client: NativeFeatureClient(transport: transport, deviceIdentifier: "test", version: "642.16"),
            receiver: receiver)
    }

    func boundDisplay(_ rotation: String, scale: Double = 3, backlight: String = "activeOn") throws
        -> NativeDisplay {
        try NativeDisplay([
            "backlightState": backlight,
            "displays": [
                [
                    "primary": true, "displayId": 1,
                    "bounds": [[0, 0], [1170, 2532]], "pointScale": scale, "currentOrientation": rotation,
                    "nativeOrientation": "rot0"
                ]
            ]
        ])
    }

}
