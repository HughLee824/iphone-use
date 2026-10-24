import Foundation
import AppleNativeBridge

func nativeUInt(_ value: UInt64) -> ASNativeUnsigned { ASNativeUnsigned(value: value) }

// These callbacks correspond to individual native RemoteXPC reply handlers, never the event channel.
protocol NativeChannel: AnyObject {
    var diagnostics: [String: Any] { get }
    func request(_ message: [String: Any], completion: @escaping ([String: Any]?, Error?) -> Void)
    func send(_ message: [String: Any], completion: @escaping (Error?) -> Void)
    func cancel()
}
extension NativeChannel { var diagnostics: [String: Any] { [:] } }

final class AppleRemoteChannel: NativeChannel {
    var diagnostics: [String: Any] { channel.diagnostics as? [String: Any] ?? [:] }
    private let channel: ASNativeChannel
    init(tunnel: ASPairedTunnel, service: String) throws { channel = try tunnel.openService(service) }
    func request(_ message: [String: Any], completion: @escaping ([String: Any]?, Error?) -> Void) {
        channel.request(message) { reply, error in completion(reply as? [String: Any], error) }
    }
    func send(_ message: [String: Any], completion: @escaping (Error?) -> Void) {
        channel.send(message, completion: completion)
    }
    func cancel() { channel.cancel() }
}

protocol NativeTransport: AnyObject {
    var diagnostics: [String: Any] { get }
    func request(_ message: [String: Any], timeout: TimeInterval) throws -> [String: Any]
    func send(_ message: [String: Any], timeout: TimeInterval) throws
    func cancel()
}
extension NativeTransport { var diagnostics: [String: Any] { [:] } }

// Late replies cannot satisfy a later request. Any timeout/cancel poisons this connection;
// opening a new workflow is explicit and never replays an old request.
final class AppleServiceTransport: NativeTransport {
    var diagnostics: [String: Any] {
        lock.lock(); let locallyClosed = closed; lock.unlock()
        // Never hold the admission lock while synchronizing with the native queue.
        var result = channel.diagnostics
        result["locallyClosed"] = locallyClosed
        return result
    }
    private final class Pending {
        let ready = DispatchSemaphore(value: 0)
        var result: Result<[String: Any], Error>?
    }
    private let channel: NativeChannel
    // Admission includes submission to the channel. Cancellation cannot finish
    // between those steps. Recursive because test/native adapters may reply inline.
    private let lock = NSRecursiveLock()
    private var pending: [UUID: Pending] = [:]
    private var closed = false

    init(channel: NativeChannel) { self.channel = channel }
    convenience init(tunnel: ASPairedTunnel, service: String) throws {
        self.init(channel: try AppleRemoteChannel(tunnel: tunnel, service: service))
    }
    func request(_ message: [String: Any], timeout: TimeInterval = 8) throws -> [String: Any] {
        try exchange(timeout: timeout) { complete in
            channel.request(message) { reply, error in
                if let error {
                    complete(.failure(error))
                } else if let reply {
                    complete(.success(reply))
                } else {
                    complete(.failure(IPhoneUseError("native_invalid_reply", "Missing native reply")))
                }
            }
        }
    }
    func send(_ message: [String: Any], timeout: TimeInterval = 3) throws {
        _ = try exchange(timeout: timeout) { complete in
            channel.send(message) { error in complete(error.map { .failure($0) } ?? .success([:])) }
        }
    }
    private func exchange(
        timeout: TimeInterval, begin: (@escaping (Result<[String: Any], Error>) -> Void) -> Void
    )
        throws -> [String: Any] {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else {
            throw IPhoneUseError("native_invalid_timeout", "Invalid native request timeout")
        }
        let deadline = DispatchTime.now() + timeout
        let id = UUID(), item = Pending()
        lock.lock()
        guard !closed else {
            lock.unlock()
            throw TransportError(
                description: "Native connection is closed; reconnect explicitly", possiblySent: false)
        }
        pending[id] = item
        begin { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            if let waiting = self.pending.removeValue(forKey: id) {
                waiting.result =
                    DispatchTime.now() < deadline
                    ? result
                    : .failure(
                        TransportError(
                            description: "Native reply arrived after the deadline; no replay",
                            possiblySent: true))
                waiting.ready.signal()
            }
            self.lock.unlock()
        }
        lock.unlock()
        if item.ready.wait(timeout: deadline) == .timedOut {
            // A callback may win the lock immediately after the wait expires. Its
            // result must not turn an already expired operation into success.
            cancel()
            throw TransportError(
                description: "Native request timed out; result is unknown, no replay", possiblySent: true)
        }
        lock.lock()
        let result = item.result
        lock.unlock()
        switch result {
        case .success(let reply): return reply
        case .failure(let error):
            cancel()
            throw TransportError(
                description: "Native request failed after admission: \(error)", possiblySent: true)
        case nil:
            throw TransportError(
                description: "Native request timed out; result is unknown, no replay", possiblySent: true)
        }
    }
    func cancel() {
        lock.lock()
        let wasClosed = closed
        closed = true
        let waiting = pending.values
        pending.removeAll()
        for item in waiting {
            item.result = .failure(
                TransportError(
                    description: "Native request cancelled or timed out; no replay", possiblySent: true))
            item.ready.signal()
        }
        if !wasClosed { channel.cancel() }
        lock.unlock()
    }
    deinit { cancel() }
}

// Media's feature envelope is separate from the HID service's request schema.
struct NativeFeatureClient {
    let transport: NativeTransport
    let deviceIdentifier: String
    let version: String

    func invoke(_ feature: String, action: String, input: [String: Any] = [:], timeout: TimeInterval = 10)
        throws
        -> [String: Any] {
        let invocation = UUID().uuidString
        let components = version.split(separator: ".").compactMap { UInt64($0) }
        guard !components.isEmpty, components.count == version.split(separator: ".").count else {
            throw IPhoneUseError(
                "native_version_unsupported", "Cannot determine the installed CoreDevice version")
        }
        let reply = try transport.request(
            [
                "CoreDevice.CoreDeviceDDIProtocolVersion": Int64(2),
                "CoreDevice.coreDeviceVersion": [
                    "components": components.map(nativeUInt),
                    "originalComponentsCount": Int64(components.count), "stringValue": version
                ],
                "CoreDevice.deviceIdentifier": deviceIdentifier,
                "CoreDevice.invocationIdentifier": invocation,
                "CoreDevice.featureIdentifier": "com.apple.coredevice.feature.\(feature)",
                "CoreDevice.actionIdentifier": "com.apple.coredevice.action.\(action)",
                "CoreDevice.action": [:], "CoreDevice.input": input
            ], timeout: timeout)
        if let echoed = reply["CoreDevice.invocationIdentifier"] as? String, echoed != invocation {
            transport.cancel()
            throw TransportError(description: "CoreDevice invocation mismatch", possiblySent: true)
        }
        guard let output = reply["CoreDevice.output"] as? [String: Any] else {
            throw IPhoneUseError(
                "native_feature_failed", "CoreDevice returned no output for \(feature): \(reply)")
        }
        return output
    }
}
