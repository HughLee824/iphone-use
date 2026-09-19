import Foundation
import Darwin
import AppleNativeBridge

protocol NativeMediaReceiver: AnyObject {
    var address: String { get }
    var port: UInt16 { get }
    func configure(_ configuration: [String: Any]) throws
    func health() -> [String: Any]
    func close()
}

// No decoder: receive RTP and send RTCP from the same owned UDP endpoint.
// Socket, timer, sequence tracking and health are confined to this queue.
final class NativeRTPReceiver: NativeMediaReceiver {
    let address: String
    let port: UInt16
    private let queue = DispatchQueue(label: "agentsoma.apple.media")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var socketFD: Int32
    private var reader: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private var peer: sockaddr_in6
    private var expectedSSRC: UInt32?
    private var localSSRC: UInt32 = 0
    private var highest: UInt32 = 0
    private var received = 0
    private var reports = 0
    private var lastPacket: TimeInterval?
    private var failed: String?

    init(deviceAddress: String) throws {
        var destination = sockaddr_in6()
        destination.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        destination.sin6_family = sa_family_t(AF_INET6)
        destination.sin6_port = UInt16(9).bigEndian // Route lookup only; no datagram is sent.
        guard inet_pton(AF_INET6, deviceAddress, &destination.sin6_addr) == 1 else { throw SomaError("native_invalid_address", "Expected device IPv6 address") }
        let routeFD = socket(AF_INET6, SOCK_DGRAM, 0)
        guard routeFD >= 0 else { throw SomaError("native_media_socket_failed", "Cannot create route socket") }
        defer { Darwin.close(routeFD) }
        let connected = withUnsafePointer(to: &destination) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(routeFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        guard connected == 0 else { throw SomaError("native_media_socket_failed", "Cannot route media to the paired device") }
        var local = sockaddr_in6(), length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let named = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(routeFD, $0, &length) } }
        guard named == 0 else { throw SomaError("native_media_socket_failed", "Cannot read receiver address") }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &local.sin6_addr, &text, socklen_t(text.count)) != nil else { throw SomaError("native_media_socket_failed", "Cannot format receiver address") }
        address = String(cString: text)
        // Use a separate explicitly bound socket. Darwin does not support Linux's
        // connect(AF_UNSPEC) UDP disconnect convention.
        let fd = socket(AF_INET6, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw SomaError("native_media_socket_failed", "Cannot create media socket") }
        var retained = false
        defer { if !retained { Darwin.close(fd) } }
        local.sin6_port = 0
        let bound = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
        } }
        guard bound == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw SomaError("native_media_socket_failed", "Cannot bind media receiver") }
        guard withUnsafeMutablePointer(to: &local, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &length)
        } }) == 0 else { throw SomaError("native_media_socket_failed", "Cannot read media port") }
        port = UInt16(bigEndian: local.sin6_port)
        var bufferSize: Int32 = 1024 * 1024
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        socketFD = fd; peer = destination; retained = true
        queue.setSpecific(key: queueKey, value: true)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        // Close only after the read source is cancelled, so a reused descriptor cannot be read.
        source.setCancelHandler { Darwin.close(fd) }
        reader = source; source.resume()
    }
    func configure(_ configuration: [String: Any]) throws {
        guard let sourcePort = configuration["SourcePort"] as? NSNumber, (1...65535).contains(sourcePort.intValue),
              let remote = configuration["LocalSSRC"] as? NSNumber, let local = configuration["RemoteSSRC"] as? NSNumber,
              configuration["RTCPEnabled"] as? Bool == true,
              let interval = configuration["RTCPSendInterval"] as? Double, interval.isFinite, interval > 0, interval <= 5,
              (configuration["SRTPCipherSuite"] as? NSNumber)?.intValue == 0 else {
            throw SomaError("native_media_unsupported", "Unsupported media/RTCP configuration")
        }
        queue.sync {
            peer.sin6_port = UInt16(sourcePort.intValue).bigEndian
            expectedSSRC = remote.uint32Value; localSSRC = local.uint32Value
            let heartbeat = DispatchSource.makeTimerSource(queue: queue)
            heartbeat.schedule(deadline: .now(), repeating: interval)
            heartbeat.setEventHandler { [weak self] in self?.feedback() }
            timer = heartbeat; heartbeat.resume()
        }
    }
    private func drain() {
        var bytes = [UInt8](repeating: 0, count: 65536)
        while socketFD >= 0 {
            var sender = sockaddr_in6(), length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let count = withUnsafeMutablePointer(to: &sender) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socketFD, &bytes, bytes.count, 0, $0, &length) }
            }
            if count < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK { failed = "media receive failed: \(errno)" }
                return
            }
            guard count >= 12, bytes[0] >> 6 == 2, !(192...223).contains(bytes[1]),
                  withUnsafeBytes(of: sender.sin6_addr, { Data($0) }) == withUnsafeBytes(of: peer.sin6_addr, { Data($0) }),
                  sender.sin6_port == peer.sin6_port, let expectedSSRC else { continue }
            let ssrc = bytes[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard ssrc == expectedSSRC else { continue }
            let sequence = UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            let delta = Int16(bitPattern: UInt16(sequence) &- UInt16(truncatingIfNeeded: highest))
            if received == 0 { highest = sequence }
            else if delta > 0 { highest &+= UInt32(delta) }
            received += 1; lastPacket = ProcessInfo.processInfo.systemUptime
        }
    }
    private func feedback() {
        guard socketFD >= 0, let expectedSSRC else { return }
        var packet = Data([0x81, 201, 0, 7])
        func append(_ value: UInt32) { var big = value.bigEndian; withUnsafeBytes(of: &big) { packet.append(contentsOf: $0) } }
        append(localSSRC); append(expectedSSRC)
        append(0); append(highest); append(0); append(0); append(0)
        let cname = Array("AgentSoma".utf8)
        var sdes = Data([0x81, 202, 0, 0])
        var ssrc = localSSRC.bigEndian; withUnsafeBytes(of: &ssrc) { sdes.append(contentsOf: $0) }
        sdes.append(contentsOf: [1, UInt8(cname.count)]); sdes.append(contentsOf: cname); sdes.append(0)
        while sdes.count % 4 != 0 { sdes.append(0) }
        let words = UInt16(sdes.count / 4 - 1); sdes[2] = UInt8(words >> 8); sdes[3] = UInt8(words & 255)
        packet.append(sdes)
        let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(socketFD, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            } }
        }
        if sent == packet.count { reports += 1 } else { failed = "RTCP send failed: \(errno)" }
    }
    func health() -> [String: Any] {
        queue.sync {
            ["rtpPackets": received, "rtcpReports": reports,
             "healthy": failed == nil && socketFD >= 0 && reports > 0 && lastPacket.map { ProcessInfo.processInfo.systemUptime - $0 < 5 } == true,
             "error": failed as Any? ?? NSNull(), "decoded": false]
        }
    }
    func close() {
        let finish = { self.timer?.cancel(); self.timer = nil; self.reader?.cancel(); self.reader = nil; self.socketFD = -1 }
        if DispatchQueue.getSpecific(key: queueKey) == true { finish() } else { queue.sync(execute: finish) }
    }
    deinit { close() }
}

final class NativeMediaSession {
    let sessionID = UUID()
    private let client: NativeFeatureClient
    private let receiver: NativeMediaReceiver
    private var mayOwnStream = false
    private var streamIdentifier: UInt32?
    private var closed = false
    private var cleanup: [String: Any]?
    init(client: NativeFeatureClient, receiver: NativeMediaReceiver) { self.client = client; self.receiver = receiver }

    func start(displayID: UInt64, deviceAddress: String, offer: Data, acceptAnswer: (Data) throws -> Void) throws {
        guard !closed, !mayOwnStream else { throw SomaError("native_media_state", "Media session cannot restart") }
        let status = try client.invoke("getmediastreamserverstatus", action: "mediastreamstatus")
        guard let sessions = status["sessions"] as? [Any] else {
            throw SomaError("native_media_unsupported", "Media ownership inventory is unavailable")
        }
        // Coexistence has not been verified. Do not disturb another client's media session.
        guard sessions.isEmpty else { throw SomaError("native_media_busy", "Another media session exists; concurrent media clients are not yet supported") }
        mayOwnStream = true // Even a lost start reply may have created our session.
        do {
            let output = try client.invoke("startmediastream", action: "mediastreamstart", input: [
                "clientSupportedFeatures": nativeUInt(140), "direction": "output", "type": "video",
                "receiverIP": receiver.address, "receiverPort": nativeUInt(UInt64(receiver.port)), "senderIP": deviceAddress,
                "timeout": nativeUInt(8), "negotiatorOffer": offer,
                "options": ["AVCMediaStreamNegotiatorAccessNetworkType": ["int": Int64(1)],
                    "AVCMediaStreamNegotiatorTransportProtocolType": ["int": Int64(2)],
                    "CoreDeviceVideoDisplayMode": ["string": "DisplayByID"],
                    "VideoStreamForDisplayID": ["int": Int64(displayID)],
                    "avcMediaStreamOptionClientSessionID": ["uuid": sessionID as NSUUID]]
            ])
            guard let connection = output["connection"] as? [String: Any],
                  let options = connection["options"] as? [String: Any],
                  let identity = options["avcMediaStreamOptionClientSessionID"] as? [String: Any],
                  let uuid = identity["uuid"] as? UUID, uuid == sessionID,
                  let config = connection["streamConfig"] as? [String: Any],
                  let answer = output["negotiatorAnswer"] as? Data else {
                throw SomaError("native_media_ownership_unknown", "Media reply did not confirm this client's session")
            }
            streamIdentifier = try Self.identifier(config)
            try acceptAnswer(answer)
            try receiver.configure(config)
        } catch { _ = close(); throw error }
    }
    func health() -> [String: Any] { receiver.health() }
    private static func identifier(_ configuration: [String: Any]) throws -> UInt32 {
        guard let value = configuration["RemoteSSRC"] as? NSNumber,
              value.doubleValue >= 1, value.doubleValue <= Double(UInt32.max), value.doubleValue.rounded() == value.doubleValue else {
            throw SomaError("native_media_ownership_unknown", "Media stream identifier is missing or invalid")
        }
        return value.uint32Value
    }
    private func ownedIdentifier(in status: [String: Any]) throws -> UInt32? {
        guard let sessions = status["sessions"] as? [[String: Any]] else {
            throw SomaError("native_media_ownership_unknown", "Media ownership inventory is unavailable")
        }
        var owned: [UInt32] = []
        for session in sessions {
            guard let connection = session["connection"] as? [String: Any],
                  let options = connection["options"] as? [String: Any],
                  let identity = options["avcMediaStreamOptionClientSessionID"] as? [String: Any],
                  let uuid = identity["uuid"] as? UUID else {
                throw SomaError("native_media_ownership_unknown", "Cannot establish ownership of a media inventory entry")
            }
            if uuid == sessionID { owned.append(try Self.identifier(connection["streamConfig"] as? [String: Any] ?? [:])) }
        }
        guard owned.count <= 1 else { throw SomaError("native_media_ownership_unknown", "Ambiguous owned media streams") }
        return owned.first
    }
    func close() -> [String: Any] {
        if let cleanup { return cleanup }
        closed = true
        var acknowledged = !mayOwnStream
        var error: String?
        if mayOwnStream {
            do {
                let before = try client.invoke("getmediastreamserverstatus", action: "mediastreamstatus")
                if let identifier = try ownedIdentifier(in: before) {
                    guard streamIdentifier == nil || streamIdentifier == identifier else {
                        throw SomaError("native_media_ownership_unknown", "Owned stream identifier changed; refusing to stop")
                    }
                    // Apple StopRequest takes UInt32 stream identifiers, not the client UUID.
                    // Bind the reported RemoteSSRC to our UUID before sending an explicit scoped stop.
                    streamIdentifier = identifier
                    _ = try client.invoke("stopmediastream", action: "mediastreamstop", input: [
                        "stopAll": false, "identifiers": [nativeUInt(UInt64(identifier))]
                    ])
                    let after = try client.invoke("getmediastreamserverstatus", action: "mediastreamstatus")
                    acknowledged = try ownedIdentifier(in: after) == nil
                } else {
                    acknowledged = true // A successful inventory query confirms our UUID is absent.
                }
            } catch let failure { error = String(describing: failure) }
        }
        receiver.close()
        let result: [String: Any] = ["mediaSessionID": sessionID.uuidString, "mediaStopAcknowledged": acknowledged,
            "mediaStreamIdentifier": streamIdentifier as Any? ?? NSNull(),
            "mediaStopError": error as Any? ?? NSNull(), "receiverClosed": true]
        cleanup = result
        return result
    }
}
