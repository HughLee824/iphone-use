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

// RFC 3550 sections 6.1, 6.4 and 6.6. Only a complete, correctly framed
// SR/RR from the negotiated source can refresh liveness; arbitrary RTCP cannot.
enum NativeRTCPReport: Equatable {
    case report, goodbye

    static func parse(_ bytes: [UInt8], expectedSSRC: UInt32) -> Self? {
        var offset = 0, reported = false, goodbye = false
        func uint32(_ index: Int) -> UInt32 {
            bytes[index..<(index + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        while offset < bytes.count {
            guard bytes.count - offset >= 4, bytes[offset] >> 6 == 2 else { return nil }
            let type = bytes[offset + 1], count = Int(bytes[offset] & 31)
            let length = ((Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])) + 1) * 4
            guard (192...223).contains(type), length >= 4, length <= bytes.count - offset else { return nil }
            var bodyLength = length
            if bytes[offset] & 32 != 0 {
                let padding = Int(bytes[offset + length - 1])
                guard offset + length == bytes.count, padding > 0, padding % 4 == 0,
                      padding <= length - 4 else { return nil }
                bodyLength -= padding
            }
            if type == 200 || type == 201 {
                let minimum = (type == 200 ? 28 : 8) + count * 24
                guard bodyLength >= minimum, uint32(offset + 4) == expectedSSRC else { return nil }
                reported = true
            } else if type == 203 {
                guard count > 0, bodyLength >= 4 + count * 4 else { return nil }
                let sourcesEnd = 4 + count * 4
                if bodyLength > sourcesEnd {
                    let reasonLength = Int(bytes[offset + sourcesEnd])
                    guard sourcesEnd + 1 + reasonLength <= bodyLength else { return nil }
                }
                for index in 0..<count where uint32(offset + 4 + index * 4) == expectedSSRC { goodbye = true }
            } else if offset == 0 {
                return nil // SDES, APP and feedback alone are not liveness reports.
            }
            offset += length
        }
        if goodbye { return .goodbye }
        return reported ? .report : nil
    }
}

// No decoder: receive RTP and send RTCP from the same owned UDP endpoint.
// Socket, timer, sequence tracking and health are confined to this queue.
final class NativeRTPReceiver: NativeMediaReceiver {
    let address: String
    let port: UInt16
    private let queue = DispatchQueue(label: "iphone-use.apple.media")
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
    private var lastReport: TimeInterval?
    private var lastReportAttempt: TimeInterval?
    private var incomingReports = 0
    private var lastIncomingReport: TimeInterval?
    private var lastValidatedReport: TimeInterval?
    private var validatedReports = 0
    private var peerEnded = false
    private var datagrams = 0
    private var rejectedDatagrams = 0
    private var reportInterval: TimeInterval?
    private let now: () -> TimeInterval
    private var failed: String?
    private var videoHandler: ((Data) -> Void)?
    private var videoConfiguration: [String: Any] = [:]
    private var videoClock = NativeRTPClock()

    init(deviceAddress: String, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        self.now = now
        var destination = sockaddr_in6()
        destination.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        destination.sin6_family = sa_family_t(AF_INET6)
        destination.sin6_port = UInt16(9).bigEndian // Route lookup only; no datagram is sent.
        guard inet_pton(AF_INET6, deviceAddress, &destination.sin6_addr) == 1 else { throw IPhoneUseError("native_invalid_address", "Expected device IPv6 address") }
        let routeFD = socket(AF_INET6, SOCK_DGRAM, 0)
        guard routeFD >= 0 else { throw IPhoneUseError("native_media_socket_failed", "Cannot create route socket") }
        defer { Darwin.close(routeFD) }
        let connected = withUnsafePointer(to: &destination) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(routeFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        guard connected == 0 else { throw IPhoneUseError("native_media_socket_failed", "Cannot route media to the paired device") }
        var local = sockaddr_in6(), length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let named = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(routeFD, $0, &length) } }
        guard named == 0 else { throw IPhoneUseError("native_media_socket_failed", "Cannot read receiver address") }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &local.sin6_addr, &text, socklen_t(text.count)) != nil else { throw IPhoneUseError("native_media_socket_failed", "Cannot format receiver address") }
        address = String(cString: text)
        // Use a separate explicitly bound socket. Darwin does not support Linux's
        // connect(AF_UNSPEC) UDP disconnect convention.
        let fd = socket(AF_INET6, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw IPhoneUseError("native_media_socket_failed", "Cannot create media socket") }
        var retained = false
        defer { if !retained { Darwin.close(fd) } }
        local.sin6_port = 0
        let bound = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
        } }
        guard bound == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw IPhoneUseError("native_media_socket_failed", "Cannot bind media receiver") }
        guard withUnsafeMutablePointer(to: &local, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &length)
        } }) == 0 else { throw IPhoneUseError("native_media_socket_failed", "Cannot read media port") }
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
            throw IPhoneUseError("native_media_unsupported", "Unsupported media/RTCP configuration")
        }
        queue.sync {
            videoConfiguration = configuration
            peer.sin6_port = UInt16(sourcePort.intValue).bigEndian
            expectedSSRC = remote.uint32Value; localSSRC = local.uint32Value
            reportInterval = interval
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
            datagrams += 1
            guard count >= 8, bytes[0] >> 6 == 2,
                  withUnsafeBytes(of: sender.sin6_addr, { Data($0) }) == withUnsafeBytes(of: peer.sin6_addr, { Data($0) }),
                  sender.sin6_port == peer.sin6_port, let expectedSSRC else { rejectedDatagrams += 1; continue }
            if (192...223).contains(bytes[1]) {
                incomingReports += 1; lastIncomingReport = now()
                switch NativeRTCPReport.parse(Array(bytes.prefix(count)), expectedSSRC: expectedSSRC) {
                case .report:
                    validatedReports += 1; lastValidatedReport = now()
                    videoClock.receive(Data(bytes.prefix(count)), ssrc: expectedSSRC)
                case .goodbye: peerEnded = true
                case nil: rejectedDatagrams += 1
                }
                continue
            }
            guard count >= 12 else { rejectedDatagrams += 1; continue }
            let ssrc = bytes[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard ssrc == expectedSSRC else { rejectedDatagrams += 1; continue }
            let sequence = UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            let delta = Int16(bitPattern: UInt16(sequence) &- UInt16(truncatingIfNeeded: highest))
            if received == 0 { highest = sequence }
            else if delta > 0 { highest &+= UInt32(delta) }
            received += 1; lastPacket = now()
            videoHandler?(Data(bytes.prefix(count)))
        }
    }
    // The handler must only enqueue bounded work; it runs on the RTP/RTCP queue.
    func setVideoHandler(_ handler: ((Data) -> Void)?) { queue.sync { videoHandler = handler } }
    func recordingConfiguration() -> [String: Any] {
        queue.sync {
            var result = videoConfiguration
            result["RTPClockRate"] = videoClock.rate
            return result
        }
    }
    func requestKeyframe() {
        queue.async { [self] in
            guard socketFD >= 0, let expectedSSRC else { return }
            // RFC 4585 PLI on the existing owned RTP/RTCP socket. No stream restart.
            var packet = Data([0x81, 206, 0, 2])
            for value in [localSSRC, expectedSSRC] {
                var big = value.bigEndian; withUnsafeBytes(of: &big) { packet.append(contentsOf: $0) }
            }
            feedback(extra: packet)
        }
    }

    private func feedback(extra: Data = Data()) {
        guard socketFD >= 0, let expectedSSRC else { return }
        var packet = Data([0x81, 201, 0, 7])
        func append(_ value: UInt32) { var big = value.bigEndian; withUnsafeBytes(of: &big) { packet.append(contentsOf: $0) } }
        append(localSSRC); append(expectedSSRC)
        append(0); append(highest); append(0); append(0); append(0)
        let cname = Array("iPhone-use".utf8)
        var sdes = Data([0x81, 202, 0, 0])
        var ssrc = localSSRC.bigEndian; withUnsafeBytes(of: &ssrc) { sdes.append(contentsOf: $0) }
        sdes.append(contentsOf: [1, UInt8(cname.count)]); sdes.append(contentsOf: cname); sdes.append(0)
        while sdes.count % 4 != 0 { sdes.append(0) }
        let words = UInt16(sdes.count / 4 - 1); sdes[2] = UInt8(words >> 8); sdes[3] = UInt8(words & 255)
        packet.append(sdes); packet.append(extra)
        lastReportAttempt = now()
        let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(socketFD, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            } }
        }
        if sent == packet.count { reports += 1; lastReport = now() } else { failed = "RTCP send failed: \(errno)" }
    }
    func health() -> [String: Any] {
        queue.sync {
            let sampledAt = now()
            func age(_ time: TimeInterval?) -> Any { time.map { max(0, sampledAt - $0) } as Any? ?? NSNull() }
            let reason: String
            if socketFD < 0 { reason = "receiver_closed" }
            else if failed != nil { reason = "io_error" }
            else if peerEnded { reason = "peer_ended" }
            else if expectedSSRC == nil { reason = "not_configured" }
            else if reports == 0 { reason = "no_rtcp_sent" }
            else if lastPacket == nil { reason = "no_rtp_received" }
            else if sampledAt - lastPacket! < 5 { reason = "recent_rtp" }
            else if let lastValidatedReport, let lastReport,
                    sampledAt - lastValidatedReport < 5, sampledAt - lastReport < 5 { reason = "recent_peer_report" }
            else { reason = "rtp_stale" }
            // Static displays can stop producing RTP. A validated report proves
            // session liveness, not a decoded frame or successful input. Startup
            // still requires RTP, and every action still captures/guards the PNG.
            return ["rtpPackets": received, "rtcpReports": reports,
             "healthy": reason == "recent_rtp" || reason == "recent_peer_report",
             "videoFlowing": lastPacket.map { sampledAt - $0 < 5 } ?? false,
             "validatedRTCPReports": validatedReports, "lastValidatedRTCPAgeSeconds": age(lastValidatedReport),
             "peerEnded": peerEnded,
             "healthReason": reason, "rtpFreshnessLimitSeconds": 5, "sampledAtUptime": sampledAt,
             "lastRTPAgeSeconds": age(lastPacket), "lastRTCPSendAgeSeconds": age(lastReport),
             "lastRTCPAttemptAgeSeconds": age(lastReportAttempt), "rtcpSendIntervalSeconds": reportInterval as Any? ?? NSNull(),
             "rtcpPacketsReceived": incomingReports, "lastRTCPReceiveAgeSeconds": age(lastIncomingReport),
             "datagramsReceived": datagrams, "rejectedDatagrams": rejectedDatagrams, "receiverOpen": socketFD >= 0,
             "error": failed as Any? ?? NSNull(), "decoded": false]
        }
    }
    func close() {
        let finish = { self.videoHandler = nil; self.timer?.cancel(); self.timer = nil; self.reader?.cancel(); self.reader = nil; self.socketFD = -1 }
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
        guard !closed, !mayOwnStream else { throw IPhoneUseError("native_media_state", "Media session cannot restart") }
        let status = try client.invoke("getmediastreamserverstatus", action: "mediastreamstatus")
        guard let sessions = status["sessions"] as? [Any] else {
            throw IPhoneUseError("native_media_unsupported", "Media ownership inventory is unavailable")
        }
        // Coexistence has not been verified. Do not disturb another client's media session.
        guard sessions.isEmpty else { throw IPhoneUseError("native_media_busy", "Another media session exists; concurrent media clients are not yet supported") }
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
                throw IPhoneUseError("native_media_ownership_unknown", "Media reply did not confirm this client's session")
            }
            streamIdentifier = try Self.identifier(config)
            try acceptAnswer(answer)
            try receiver.configure(config)
        } catch { _ = close(); throw error }
    }
    var recordingReceiver: NativeRTPReceiver? { receiver as? NativeRTPReceiver }
    func health() -> [String: Any] {
        var result = receiver.health()
        result["displayConnection"] = client.transport.diagnostics
        return result
    }
    private static func identifier(_ configuration: [String: Any]) throws -> UInt32 {
        guard let value = configuration["RemoteSSRC"] as? NSNumber,
              value.doubleValue >= 1, value.doubleValue <= Double(UInt32.max), value.doubleValue.rounded() == value.doubleValue else {
            throw IPhoneUseError("native_media_ownership_unknown", "Media stream identifier is missing or invalid")
        }
        return value.uint32Value
    }
    private func ownedIdentifier(in status: [String: Any]) throws -> UInt32? {
        guard let sessions = status["sessions"] as? [[String: Any]] else {
            throw IPhoneUseError("native_media_ownership_unknown", "Media ownership inventory is unavailable")
        }
        var owned: [UInt32] = []
        for session in sessions {
            guard let connection = session["connection"] as? [String: Any],
                  let options = connection["options"] as? [String: Any],
                  let identity = options["avcMediaStreamOptionClientSessionID"] as? [String: Any],
                  let uuid = identity["uuid"] as? UUID else {
                throw IPhoneUseError("native_media_ownership_unknown", "Cannot establish ownership of a media inventory entry")
            }
            if uuid == sessionID { owned.append(try Self.identifier(connection["streamConfig"] as? [String: Any] ?? [:])) }
        }
        guard owned.count <= 1 else { throw IPhoneUseError("native_media_ownership_unknown", "Ambiguous owned media streams") }
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
                        throw IPhoneUseError("native_media_ownership_unknown", "Owned stream identifier changed; refusing to stop")
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
