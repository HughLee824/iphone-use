import Foundation

struct NativeRTPPacket {
    let sequence: UInt16
    let timestamp: UInt32
    let ssrc: UInt32
    let payloadType: UInt8
    let marker: Bool
    let payload: Data
    let displayRotation: String?

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0] >> 6 == 2 else { throw Self.invalid() }
        func word(_ offset: Int) -> Int { Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }
        func uint32(_ offset: Int) -> UInt32 {
            bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        var offset = 12 + Int(bytes[0] & 15) * 4
        var rotation: String?
        guard offset <= bytes.count else { throw Self.invalid() }
        if bytes[0] & 16 != 0 {
            guard offset + 4 <= bytes.count else { throw Self.invalid() }
            let profile = word(offset), words = word(offset + 2)
            // macOS/iOS 27 DisplayService one-word AVC extension, verified with
            // portrait/left/right captures (0/3/2), with/without the IDR flag.
            // Unknown profiles and the unverified value 1 supply no evidence.
            if words == 1, [0x9001, 0x9011].contains(profile & 0xfcff) {
                rotation = [0: "rot0", 2: "rot270", 3: "rot90"][(profile >> 8) & 3]
            }
            offset += 4 + word(offset + 2) * 4
        }
        var end = bytes.count
        if bytes[0] & 32 != 0 {
            let padding = Int(bytes[bytes.count - 1])
            guard padding > 0, padding <= end - offset else { throw Self.invalid() }
            end -= padding
        }
        guard offset < end else { throw Self.invalid() }
        sequence = UInt16(word(2)); timestamp = uint32(4); ssrc = uint32(8)
        marker = bytes[1] & 128 != 0; payloadType = bytes[1] & 127
        payload = Data(bytes[offset..<end])
        displayRotation = rotation
    }
    private static func invalid() -> IPhoneUseError {
        IPhoneUseError("recording_rtp_invalid", "Malformed RTP header or empty payload")
    }
}

struct NativeVideoAccessUnit {
    let timestamp: UInt32
    let nals: [Data]
    let keyframe: Bool
    var firstPacketAt: Double?
    var displayRotation: String?
}

// RFC 7798 single-layer HEVC without DONL: single NAL, AP and FU. Late or missing
// packets discard the damaged access unit and all dependent frames until IDR.
// Bounds apply before appending; malformed video never affects RTCP liveness.
struct NativeHEVCDepacketizer {
    private var expected: UInt16?
    private var timestamp: UInt32?
    private var firstPacketAt: Double?
    private var displayRotation: String?
    private var rotationConsistent = true
    private var nals: [Data] = []
    private var fragment = Data()
    private var fragmentHeader: Data?
    private var size = 0
    private var damaged = false
    private(set) var waitingForKeyframe = true
    private(set) var droppedUnits = 0
    private(set) var discontinuities = 0
    private(set) var malformedPackets = 0
    private let maximumBytes = 8 * 1024 * 1024

    mutating func receive(_ packet: NativeRTPPacket, receivedAt: Double? = nil) -> NativeVideoAccessUnit? {
        var sequenceGap = false
        if let expected, expected != packet.sequence {
            // A duplicate/late packet must not advance expected or corrupt a
            // correctly ordered in-progress frame. A future packet means loss.
            if Int16(bitPattern: packet.sequence &- expected) < 0 { return nil }
            discontinuities += 1; sequenceGap = true; waitingForKeyframe = true
        }
        expected = packet.sequence &+ 1
        if let timestamp, timestamp != packet.timestamp {
            if !nals.isEmpty || !fragment.isEmpty { droppedUnits += 1; waitingForKeyframe = true }
            resetUnit()
        }
        // Apply loss AFTER changing units: resetUnit must not erase damage on
        // the first received packet of a new timestamp (possibly a partial IDR).
        if sequenceGap { damaged = true }
        if timestamp == nil {
            firstPacketAt = receivedAt; displayRotation = packet.displayRotation
        } else if displayRotation != packet.displayRotation {
            rotationConsistent = false
        }
        timestamp = packet.timestamp
        do { try append(packet.payload) } catch {
            malformedPackets += 1; damaged = true; waitingForKeyframe = true
        }
        guard packet.marker else { return nil }
        return finishUnit(packet)
    }

    private mutating func finishUnit(_ packet: NativeRTPPacket) -> NativeVideoAccessUnit? {
        defer { resetUnit() }
        guard !damaged, fragment.isEmpty, !nals.isEmpty else { droppedUnits += 1; return nil }
        let keyframe = nals.contains { $0.first.map { (19...20).contains(($0 >> 1) & 63) } == true }
        let video = nals.contains { $0.first.map { ($0 >> 1) & 63 <= 31 } == true }
        // Parameter-set-only units can update the format while waiting for IDR.
        if video, waitingForKeyframe, !keyframe { droppedUnits += 1; return nil }
        if keyframe { waitingForKeyframe = false }
        return NativeVideoAccessUnit(
            timestamp: packet.timestamp, nals: nals, keyframe: keyframe, firstPacketAt: firstPacketAt,
            displayRotation: rotationConsistent ? displayRotation : nil)
    }

    private mutating func resetUnit() {
        nals.removeAll(keepingCapacity: true); fragment.removeAll(keepingCapacity: true)
        fragmentHeader = nil; size = 0; damaged = false; timestamp = nil; firstPacketAt = nil
        displayRotation = nil; rotationConsistent = true
    }
    private mutating func add(_ nal: Data) throws {
        guard nal.count >= 2, nal[0] & 129 == 0, nal[1] == 1, (nal[0] >> 1) & 63 < 48,
            nals.count < 256, size + nal.count <= maximumBytes
        else { throw invalid() }
        size += nal.count; nals.append(nal)
    }
    private func invalid() -> IPhoneUseError {
        IPhoneUseError("recording_hevc_invalid", "Malformed, oversized or unsupported HEVC RTP payload")
    }
    private mutating func append(_ payload: Data) throws {
        let secondSample = [UInt8](payload)
        guard secondSample.count >= 2, secondSample[0] & 129 == 0, secondSample[1] == 1 else {
            throw invalid()
        }
        switch (secondSample[0] >> 1) & 63 {
        case 0...47:
            guard fragment.isEmpty else { throw invalid() }
            try add(payload)
        case 48:
            try appendAggregation(secondSample)
        case 49:
            try appendFragment(secondSample)
        default: throw invalid()
        }
    }
    private mutating func appendAggregation(_ secondSample: [UInt8]) throws {
        guard fragment.isEmpty else { throw invalid() }
        var offset = 2
        while offset < secondSample.count {
            guard offset + 2 <= secondSample.count else { throw invalid() }
            let length = Int(secondSample[offset]) << 8 | Int(secondSample[offset + 1]); offset += 2
            guard length > 0, offset + length <= secondSample.count else { throw invalid() }
            try add(Data(secondSample[offset..<offset + length])); offset += length
        }
    }

    private mutating func appendFragment(_ secondSample: [UInt8]) throws {
        guard secondSample.count > 3, secondSample[2] & 63 < 48 else { throw invalid() }
        let start = secondSample[2] & 128 != 0, end = secondSample[2] & 64 != 0
        let header = Data([(secondSample[0] & 129) | ((secondSample[2] & 63) << 1), secondSample[1]])
        guard !(start && end) else { throw invalid() }
        if start {
            guard fragment.isEmpty else { throw invalid() }
            fragment = header; fragmentHeader = header
        } else {
            guard !fragment.isEmpty, fragmentHeader == header else { throw invalid() }
        }
        guard size + fragment.count + secondSample.count - 3 <= maximumBytes else { throw invalid() }
        fragment.append(contentsOf: secondSample.dropFirst(3))
        if end { try add(fragment); fragment.removeAll(keepingCapacity: true); fragmentHeader = nil }
    }

}

// Derive the actual clock from two validated peer RTCP sender reports. The
// observed Apple HEVC stream uses 24 kHz, despite RFC 7798's 90 kHz convention.
struct NativeRTPClock {
    private var previous: (seconds: Double, timestamp: UInt32)?
    private(set) var rate: Int32?
    mutating func receive(_ data: Data, ssrc: UInt32) {
        let bytes = [UInt8](data)
        guard bytes.count >= 28, bytes[1] == 200,
            NativeRTCPReport.parse(bytes, expectedSSRC: ssrc) == .report
        else { return }
        func number(_ offset: Int) -> UInt32 {
            bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        guard number(4) == ssrc else { return }
        let seconds = Double(number(8)) + Double(number(12)) / 4294967296
        let timestamp = number(16)
        defer { previous = (seconds, timestamp) }
        guard let previous else { return }
        let interval = seconds - previous.seconds
        guard interval > 0.2, interval < 10 else { return }
        let measured = Double(timestamp &- previous.timestamp) / interval
        guard let candidate = [Int32(24000), 90000].first(where: { abs(measured / Double($0) - 1) < 0.005 })
        else {
            rate = nil; return
        }
        rate = candidate
    }
}
