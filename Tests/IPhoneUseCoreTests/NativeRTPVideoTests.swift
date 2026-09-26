import XCTest
@testable import IPhoneUseCore

final class NativeRTPVideoTests: XCTestCase {
    func testFreshnessKeepsFirstPacketTimeAcrossLateDuplicates() throws {
        var parser = NativeHEVCDepacketizer()
        XCTAssertNotNil(parser.receive(try packet(1, [0x28,1,1]), receivedAt: 1))
        XCTAssertNil(parser.receive(try packet(2, [0x62,1,0x81,1], timestamp: 2, marker: false), receivedAt: 2))
        XCTAssertNil(parser.receive(try packet(1, [0x28,1,1]), receivedAt: 3))
        let unit = parser.receive(try packet(3, [0x62,1,0x41,2], timestamp: 2), receivedAt: 4)
        XCTAssertEqual(unit?.firstPacketAt, 2)
    }
    func testSenderReportsMeasureClockAndRejectForeignMalformedOrUnknownRates() {
        func report(_ seconds: UInt32, _ timestamp: UInt32, ssrc: UInt32 = 123) -> Data {
            var data = Data([0x80, 200, 0, 6])
            for value in [ssrc, seconds, 0, timestamp, 0, 0] {
                var big = value.bigEndian; withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
            }
            return data
        }
        var clock = NativeRTPClock()
        clock.receive(report(1, UInt32.max - 12000), ssrc: 123)
        XCTAssertNil(clock.rate)
        clock.receive(report(2, 11999, ssrc: 456), ssrc: 123)
        XCTAssertNil(clock.rate)
        var broken = report(2, 11999); broken[3] = 255
        clock.receive(broken, ssrc: 123); XCTAssertNil(clock.rate)
        clock.receive(report(2, 11999), ssrc: 123)
        XCTAssertEqual(clock.rate, 24000)
        clock.receive(report(3, 101999), ssrc: 123)
        XCTAssertEqual(clock.rate, 90000)
        clock.receive(report(4, 102999), ssrc: 123)
        XCTAssertNil(clock.rate)
    }
    private func packet(_ sequence: UInt16, _ payload: [UInt8], timestamp: UInt32 = 1, marker: Bool = true) throws -> NativeRTPPacket {
        var data = Data([0x80, marker ? 0xe0 : 0x60, UInt8(sequence >> 8), UInt8(sequence & 255)])
        for value: UInt32 in [timestamp, 123] { var big = value.bigEndian; withUnsafeBytes(of: &big) { data.append(contentsOf: $0) } }
        data.append(contentsOf: payload); return try NativeRTPPacket(data)
    }
    func testRTPHeaderBoundsExtensionsAndPadding() throws {
        for bytes: [UInt8] in [[], [0x80], Array(repeating: 0, count: 12), [0x8f,0] + Array(repeating: 0, count: 11)] {
            XCTAssertThrowsError(try NativeRTPPacket(Data(bytes)))
        }
        let data = Data([0xb1,0xe0,0,2,0,0,0,3,0,0,0,4,0,0,0,5,0xbe,0xde,0,1,1,2,3,4,0x65,9,0,2])
        let p = try NativeRTPPacket(data)
        XCTAssertEqual(p.payload, Data([0x65,9])); XCTAssertEqual(p.sequence, 2); XCTAssertEqual(p.timestamp, 3)
        XCTAssertEqual(p.ssrc, 4); XCTAssertTrue(p.marker); XCTAssertEqual(p.payloadType, 96)
        var broken = data; broken[19] = 100
        XCTAssertThrowsError(try NativeRTPPacket(broken))
    }
    func testSingleAggregationFragmentAndSequenceWrap() throws {
        var parser = NativeHEVCDepacketizer()
        XCTAssertNil(parser.receive(try packet(65533, [0x02,1,1])))
        let parameter = parser.receive(try packet(65534, [0x60,1,0,3,0x40,1,1,0,3,0x42,1,2], timestamp: 2))
        XCTAssertEqual(parameter?.nals, [Data([0x40,1,1]),Data([0x42,1,2])])
        XCTAssertNil(parser.receive(try packet(65535,[0x62,1,0x94,10,11],timestamp:3,marker:false)))
        let frame = parser.receive(try packet(0,[0x62,1,0x54,12,13],timestamp:3))
        XCTAssertEqual(frame?.nals, [Data([0x28,1,10,11,12,13])]); XCTAssertEqual(frame?.keyframe,true)
        XCTAssertFalse(parser.waitingForKeyframe)
        XCTAssertNotNil(parser.receive(try packet(1,[0x02,1,5],timestamp:4)))
    }
    func testLossDropsDependenciesUntilIDRAndLateDuplicateCannotDamageFrame() throws {
        var parser = NativeHEVCDepacketizer()
        XCTAssertNotNil(parser.receive(try packet(1,[0x28,1,1])))
        XCTAssertNil(parser.receive(try packet(2,[0x62,1,0x81,1],timestamp:2,marker:false)))
        XCTAssertNil(parser.receive(try packet(4,[0x62,1,0x41,2],timestamp:2)))
        XCTAssertNil(parser.receive(try packet(5,[0x02,1,1],timestamp:3)))
        XCTAssertNotNil(parser.receive(try packet(6,[0x28,1,1],timestamp:4)))
        XCTAssertNil(parser.receive(try packet(6,[0x28,1,1],timestamp:4)))
        XCTAssertNotNil(parser.receive(try packet(7,[0x02,1,1],timestamp:5)))
        XCTAssertEqual(parser.discontinuities,1)
    }
    func testMalformedFragmentsAndMissingMarkerDoNotLeakPartialFrames() throws {
        for payload: [UInt8] in [[0x62,1,0xd4,1],[0x62,1,0x54,1],[0x60,1,0,4,0x28],[0x64,1],[0xa8,1]] {
            var parser = NativeHEVCDepacketizer()
            XCTAssertNil(parser.receive(try packet(1,payload)))
            XCTAssertTrue(parser.waitingForKeyframe); XCTAssertGreaterThan(parser.malformedPackets,0)
        }
        var parser = NativeHEVCDepacketizer()
        XCTAssertNil(parser.receive(try packet(1,[0x28,1,1],marker:false)))
        XCTAssertNil(parser.receive(try packet(2,[0x02,1,1],timestamp:2)))
        XCTAssertNotNil(parser.receive(try packet(3,[0x28,1,1],timestamp:3)))
    }
}
