import Foundation
import Darwin
import AppleNativeBridge

extension NativeRTPReceiver {
    func drain() {
        var bytes = [UInt8](repeating: 0, count: 65536)
        while socketFD >= 0 {
            var sender = sockaddr_in6(), length = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let count = withUnsafeMutablePointer(to: &sender) { packet in
                packet.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(socketFD, &bytes, bytes.count, 0, $0, &length)
                }
            }
            if count < 0 {
                if errno != EAGAIN && errno != EWOULDBLOCK { failed = "media receive failed: \(errno)" }
                return
            }
            datagrams += 1
            guard count >= 8, bytes[0] >> 6 == 2,
                withUnsafeBytes(of: sender.sin6_addr, { Data($0) })
                    == withUnsafeBytes(of: peer.sin6_addr, { Data($0) }),
                sender.sin6_port == peer.sin6_port, let expectedSSRC
            else { rejectedDatagrams += 1; continue }
            if (192...223).contains(bytes[1]) {
                receiveReport(bytes, count: count, expectedSSRC: expectedSSRC)
                continue
            }
            guard count >= 12 else { rejectedDatagrams += 1; continue }
            let ssrc = bytes[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard ssrc == expectedSSRC else { rejectedDatagrams += 1; continue }
            let sequence = UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            let delta = Int16(bitPattern: UInt16(sequence) &- UInt16(truncatingIfNeeded: highest))
            if received == 0 { highest = sequence } else if delta > 0 { highest &+= UInt32(delta) }
            received += 1; lastPacket = now()
            let packet = Data(bytes.prefix(count))
            videoHandler?(packet)
            if snapshotFormatSupported { snapshots?.receive(packet, at: lastPacket!) }
        }
    }
    private func receiveReport(_ bytes: [UInt8], count: Int, expectedSSRC: UInt32) {
        incomingReports += 1; lastIncomingReport = now()
        switch NativeRTCPReport.parse(Array(bytes.prefix(count)), expectedSSRC: expectedSSRC) {
        case .report:
            validatedReports += 1; lastValidatedReport = now()
            videoClock.receive(Data(bytes.prefix(count)), ssrc: expectedSSRC)
        case .goodbye: peerEnded = true
        case nil: rejectedDatagrams += 1
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

    func feedback(extra: Data = Data()) {
        guard socketFD >= 0, let expectedSSRC else { return }
        var packet = Data([0x81, 201, 0, 7])
        func append(_ value: UInt32) {
            var big = value.bigEndian; withUnsafeBytes(of: &big) { packet.append(contentsOf: $0) }
        }
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
            withUnsafePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(
                        socketFD, bytes.baseAddress, bytes.count, 0, $0,
                        socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        if sent == packet.count {
            reports += 1; lastReport = now()
        } else {
            failed = "RTCP send failed: \(errno)"
        }
    }
}
