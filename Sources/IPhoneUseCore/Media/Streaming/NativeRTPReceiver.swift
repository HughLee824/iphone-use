import Foundation
import Darwin
import AppleNativeBridge

// No decoder: receive RTP and send RTCP from the same owned UDP endpoint.
// Socket, timer, sequence tracking and health are confined to this queue.
final class NativeRTPReceiver: NativeMediaReceiver {
    let address: String
    let port: UInt16
    let queue = DispatchQueue(label: "iphone-use.apple.media", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    var socketFD: Int32
    private var reader: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    var peer: sockaddr_in6
    var expectedSSRC: UInt32?
    var localSSRC: UInt32 = 0
    var highest: UInt32 = 0
    var received = 0
    var reports = 0
    var lastPacket: TimeInterval?
    var lastReport: TimeInterval?
    var lastReportAttempt: TimeInterval?
    var incomingReports = 0
    var lastIncomingReport: TimeInterval?
    var lastValidatedReport: TimeInterval?
    var validatedReports = 0
    var peerEnded = false
    var datagrams = 0
    var rejectedDatagrams = 0
    private var reportInterval: TimeInterval?
    let now: () -> TimeInterval
    var failed: String?
    var videoHandler: ((Data) -> Void)?
    private var videoConfiguration: [String: Any] = [:]
    var videoClock = NativeRTPClock()
    let snapshots: NativeVideoSnapshot?
    var snapshotFormatSupported = false

    init(
        deviceAddress: String, captureSnapshots: Bool = false,
        makeSnapshots: () -> NativeVideoSnapshot = { NativeVideoSnapshot() },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) throws {
        self.now = now
        snapshots = captureSnapshots ? makeSnapshots() : nil
        var destination = sockaddr_in6()
        destination.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        destination.sin6_family = sa_family_t(AF_INET6)
        destination.sin6_port = UInt16(9).bigEndian // Route lookup only; no datagram is sent.
        guard inet_pton(AF_INET6, deviceAddress, &destination.sin6_addr) == 1 else {
            throw IPhoneUseError("native_invalid_address", "Expected device IPv6 address")
        }
        let routeFD = socket(AF_INET6, SOCK_DGRAM, 0)
        guard routeFD >= 0 else { throw IPhoneUseError("native_media_socket_failed", "Cannot create route socket") }
        defer { Darwin.close(routeFD) }
        var local = try Self.routeAddress(routeFD, destination: destination)
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &local.sin6_addr, &text, socklen_t(text.count)) != nil else {
            throw IPhoneUseError("native_media_socket_failed", "Cannot format receiver address")
        }
        address = String(cString: text)
        // Use a separate explicitly bound socket. Darwin does not support Linux's
        // connect(AF_UNSPEC) UDP disconnect convention.
        let descriptor = socket(AF_INET6, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw IPhoneUseError("native_media_socket_failed", "Cannot create media socket") }
        var retained = false
        defer { if !retained { Darwin.close(descriptor) } }
        local.sin6_port = 0
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw IPhoneUseError("native_media_socket_failed", "Cannot bind media receiver")
        }
        guard
            withUnsafeMutablePointer(
                to: &local,
                { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }) == 0
        else { throw IPhoneUseError("native_media_socket_failed", "Cannot read media port") }
        port = UInt16(bigEndian: local.sin6_port)
        var bufferSize: Int32 = 1024 * 1024
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        socketFD = descriptor
        peer = destination
        retained = true
        queue.setSpecific(key: queueKey, value: true)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        // Close only after the read source is cancelled, so a reused descriptor cannot be read.
        source.setCancelHandler { Darwin.close(descriptor) }
        reader = source
        source.resume()
    }
    private static func routeAddress(_ routeFD: Int32, destination: sockaddr_in6) throws -> sockaddr_in6 {
        var destination = destination
        let connected = withUnsafePointer(to: &destination) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(routeFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard connected == 0 else {
            throw IPhoneUseError("native_media_socket_failed", "Cannot route media to the paired device")
        }
        var local = sockaddr_in6(), length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(routeFD, $0, &length) }
        }
        guard named == 0 else { throw IPhoneUseError("native_media_socket_failed", "Cannot read receiver address") }
        return local
    }

    func configure(_ configuration: [String: Any]) throws {
        guard let sourcePort = configuration["SourcePort"] as? NSNumber, (1...65535).contains(sourcePort.intValue),
            let remote = configuration["LocalSSRC"] as? NSNumber, let local = configuration["RemoteSSRC"] as? NSNumber,
            configuration["RTCPEnabled"] as? Bool == true, let interval = configuration["RTCPSendInterval"] as? Double,
            interval.isFinite, interval > 0, interval <= 5,
            (configuration["SRTPCipherSuite"] as? NSNumber)?.intValue == 0
        else { throw IPhoneUseError("native_media_unsupported", "Unsupported media/RTCP configuration") }
        queue.sync {
            videoConfiguration = configuration
            snapshotFormatSupported = NativeStreamRecording.supports(configuration)
            peer.sin6_port = UInt16(sourcePort.intValue).bigEndian
            expectedSSRC = remote.uint32Value
            localSSRC = local.uint32Value
            reportInterval = interval
            let heartbeat = DispatchSource.makeTimerSource(queue: queue)
            heartbeat.schedule(deadline: .now(), repeating: interval)
            heartbeat.setEventHandler { [weak self] in self?.feedback() }
            timer = heartbeat
            heartbeat.resume()
        }
    }
    // The handler must only enqueue bounded work; it runs on the RTP/RTCP queue.
    func setVideoHandler(_ handler: ((Data) -> Void)?) { queue.sync { videoHandler = handler } }
    func snapshot(
        after requestedAt: Double, timeout: Double = 0.15, includeReducedResolution: Bool = false,
        cancellation: NativeCancellation
    ) throws -> NativeVideoSnapshot.Frame? {
        guard let snapshots else { return nil }
        // Exclude datagrams already waiting in the socket as well as packets in
        // the decoder queue. A host receive time is not a device capture clock.
        let barrier = queue.sync {
            drain()
            return now()
        }
        return try snapshots.frame(
            after: max(requestedAt, barrier), timeout: timeout, includeReducedResolution: includeReducedResolution,
            cancellation: cancellation)
    }
    func recordingConfiguration() -> [String: Any] {
        queue.sync {
            var result = videoConfiguration
            result["RTPClockRate"] = videoClock.rate
            return result
        }
    }
    func health() -> [String: Any] {
        queue.sync {
            let sampledAt = now()
            func age(_ time: TimeInterval?) -> Any { time.map { max(0, sampledAt - $0) } as Any? ?? NSNull() }
            let reason: String
            if socketFD < 0 {
                reason = "receiver_closed"
            } else if failed != nil {
                reason = "io_error"
            } else if peerEnded {
                reason = "peer_ended"
            } else if expectedSSRC == nil {
                reason = "not_configured"
            } else if reports == 0 {
                reason = "no_rtcp_sent"
            } else if lastPacket == nil {
                reason = "no_rtp_received"
            } else if sampledAt - lastPacket! < 5 {
                reason = "recent_rtp"
            } else if let lastValidatedReport, let lastReport, sampledAt - lastValidatedReport < 5,
                sampledAt - lastReport < 5 {
                reason = "recent_peer_report"
            } else {
                reason = "rtp_stale"
            }
            // Static displays can stop producing RTP. A validated report proves
            // session liveness, not a decoded frame or successful input. Startup
            // still requires RTP, and every action still captures/guards the PNG.
            return [
                "rtpPackets": received, "rtcpReports": reports,
                "healthy": reason == "recent_rtp" || reason == "recent_peer_report",
                "videoFlowing": lastPacket.map { sampledAt - $0 < 5 } ?? false,
                "validatedRTCPReports": validatedReports, "lastValidatedRTCPAgeSeconds": age(lastValidatedReport),
                "peerEnded": peerEnded, "healthReason": reason, "rtpFreshnessLimitSeconds": 5,
                "sampledAtUptime": sampledAt, "lastRTPAgeSeconds": age(lastPacket),
                "lastRTCPSendAgeSeconds": age(lastReport), "lastRTCPAttemptAgeSeconds": age(lastReportAttempt),
                "rtcpSendIntervalSeconds": reportInterval as Any? ?? NSNull(), "rtcpPacketsReceived": incomingReports,
                "lastRTCPReceiveAgeSeconds": age(lastIncomingReport), "datagramsReceived": datagrams,
                "rejectedDatagrams": rejectedDatagrams, "receiverOpen": socketFD >= 0,
                "error": failed as Any? ?? NSNull(), "decoded": (snapshots?.status()["decodedFrames"] as? Int ?? 0) > 0,
                "snapshots": snapshots?.status() as Any? ?? NSNull()
            ]
        }
    }
    func close() {
        let finish = {
            self.videoHandler = nil
            self.timer?.cancel()
            self.timer = nil
            self.reader?.cancel()
            self.reader = nil
            self.socketFD = -1
        }
        if DispatchQueue.getSpecific(key: queueKey) == true { finish() } else { queue.sync(execute: finish) }
        snapshots?.close()
    }
    deinit { close() }
}
