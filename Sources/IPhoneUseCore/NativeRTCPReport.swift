import Foundation
import Darwin
import AppleNativeBridge

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
            guard let bodyLength = unpaddedLength(bytes, offset: offset, length: length) else { return nil }
            if type == 200 || type == 201 {
                let minimum = (type == 200 ? 28 : 8) + count * 24
                guard bodyLength >= minimum, uint32(offset + 4) == expectedSSRC else { return nil }
                reported = true
            } else if type == 203 {
                guard
                    let matched = goodbyeSource(
                        bytes, offset: offset, count: count,
                        bodyLength: bodyLength, expectedSSRC: expectedSSRC)
                else { return nil }
                goodbye = goodbye || matched
            } else if offset == 0 {
                return nil // SDES, APP and feedback alone are not liveness reports.
            }
            offset += length
        }
        if goodbye { return .goodbye }
        return reported ? .report : nil
    }
    private static func unpaddedLength(_ bytes: [UInt8], offset: Int, length: Int) -> Int? {
        var bodyLength = length
        if bytes[offset] & 32 != 0 {
            let padding = Int(bytes[offset + length - 1])
            guard offset + length == bytes.count, padding > 0, padding % 4 == 0,
                padding <= length - 4
            else { return nil }
            bodyLength -= padding
        }
        return bodyLength
    }

    private static func goodbyeSource(
        _ bytes: [UInt8], offset: Int, count: Int,
        bodyLength: Int, expectedSSRC: UInt32
    ) -> Bool? {
        guard count > 0, bodyLength >= 4 + count * 4 else { return nil }
        let sourcesEnd = 4 + count * 4
        if bodyLength > sourcesEnd {
            let reasonLength = Int(bytes[offset + sourcesEnd])
            guard sourcesEnd + 1 + reasonLength <= bodyLength else { return nil }
        }
        return (0..<count).contains { index in
            bytes[(offset + 4 + index * 4)..<(offset + 8 + index * 4)].reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
                == expectedSSRC
        }
    }

}
