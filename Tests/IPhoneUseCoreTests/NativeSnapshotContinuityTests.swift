import XCTest
import CoreVideo
@testable import IPhoneUseCore

final class NativeSnapshotContinuityTests: XCTestCase {
    private func packet(_ sequence: UInt16, timestamp: UInt32, type: UInt8 = 20, marker: Bool = true) -> Data {
        var data = Data([0x80, marker ? 0xe4 : 0x64, UInt8(sequence >> 8), UInt8(sequence & 255)])
        for value: UInt32 in [timestamp, 123] {
            var big = value.bigEndian; withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: [type << 1, 1, 1]); return data
    }
    private func idle(_ stream: NativeVideoSnapshot) {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            stream.status()["pendingBytes"] as? Int == 0
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 2), .completed)
    }
    private func pixels() throws -> NativeDecodedVideoFrame {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 12, 18, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        return NativeDecodedVideoFrame(pixels: try XCTUnwrap(buffer), nativeWidth: 12, nativeHeight: 18)
    }
    func testTimingDistinguishesQueuedPacketsFromSlowDecode() throws {
        let pixel = try pixels(), entered = expectation(description: "decoder entered")
        let release = DispatchSemaphore(value: 0)
        let stream = NativeVideoSnapshot(decode: { unit in
            if unit.timestamp == 1 { entered.fulfill(); _ = release.wait(timeout: .now() + 3) }
            return pixel
        }, resetDecoder: {})
        defer { release.signal(); stream.close() }
        stream.receive(packet(1, timestamp: 1), at: ProcessInfo.processInfo.systemUptime)
        wait(for: [entered], timeout: 2)
        stream.receive(packet(2, timestamp: 2), at: ProcessInfo.processInfo.systemUptime)
        Thread.sleep(forTimeInterval: 0.12)
        release.signal(); idle(stream)
        let timing = try XCTUnwrap(stream.status()["timing"] as? [String: Any])
        let events = try XCTUnwrap(timing["slowFrames"] as? [[String: Double]])
        let slow = try XCTUnwrap(events.first { $0["timestamp"] == 1 })
        let queued = try XCTUnwrap(events.first { $0["timestamp"] == 2 })
        XCTAssertGreaterThan(slow["decodeMs"]!, 100)
        XCTAssertGreaterThan(queued["queueWaitMs"]!, 100)
        XCTAssertGreaterThanOrEqual(queued["sourceLagMs"]!, queued["decodeMs"]!)
        XCTAssertEqual(stream.status()["decodedFrames"] as? Int, 2)
    }

    func testTimestampRejectionInvalidatesLatestAndRequiresKeyframeBeforeDecodingAgain() throws {
        let pixel = try pixels()
        var timestamps: [UInt32] = [], resets = 0
        let stream = NativeVideoSnapshot(decode: { timestamps.append($0.timestamp); return pixel }, resetDecoder: { resets += 1 })
        defer { stream.close() }
        let start = ProcessInfo.processInfo.systemUptime
        stream.receive(packet(1, timestamp: 10), at: start)
        XCTAssertNotNil(try stream.frame(after: start, timeout: 0.4, cancellation: NativeCancellation()))
        idle(stream)
        // A second video unit shares the timestamp but has a new RTP sequence.
        stream.receive(packet(2, timestamp: 10, type: 1), at: ProcessInfo.processInfo.systemUptime)
        idle(stream)
        XCTAssertNil(try stream.frame(after: start, timeout: 0, cancellation: NativeCancellation()))
        XCTAssertEqual(stream.status()["timestampRejections"] as? Int, 1)
        stream.receive(packet(3, timestamp: 11, type: 1), at: ProcessInfo.processInfo.systemUptime)
        idle(stream)
        XCTAssertEqual(timestamps, [10], "Dependent frames must not reach the old decoder")
        stream.receive(packet(4, timestamp: 12), at: ProcessInfo.processInfo.systemUptime)
        idle(stream)
        XCTAssertEqual(timestamps, [10, 12])
        XCTAssertGreaterThan(resets, 0)
    }
    func testCrossUnitPacketLossClearsLatestAndDoesNotDecodeDamagedIDR() throws {
        let pixel = try pixels()
        var timestamps: [UInt32] = []
        let stream = NativeVideoSnapshot(decode: { timestamps.append($0.timestamp); return pixel }, resetDecoder: {})
        defer { stream.close() }
        let start = ProcessInfo.processInfo.systemUptime
        stream.receive(packet(1, timestamp: 1), at: start)
        XCTAssertNotNil(try stream.frame(after: start, timeout: 0.4, cancellation: NativeCancellation()))
        idle(stream)
        stream.receive(packet(2, timestamp: 2, type: 1, marker: false), at: ProcessInfo.processInfo.systemUptime)
        idle(stream)
        stream.receive(packet(4, timestamp: 3), at: ProcessInfo.processInfo.systemUptime)
        idle(stream)
        XCTAssertNil(try stream.frame(after: start, timeout: 0, cancellation: NativeCancellation()))
        XCTAssertEqual(stream.status()["discontinuities"] as? Int, 1)
        XCTAssertEqual(stream.status()["waitingForKeyframe"] as? Bool, true)
        stream.receive(packet(5, timestamp: 4, type: 1), at: ProcessInfo.processInfo.systemUptime)
        idle(stream)
        stream.receive(packet(6, timestamp: 5), at: ProcessInfo.processInfo.systemUptime)
        idle(stream)
        XCTAssertEqual(timestamps, [1, 5])
    }
    func testTimestampWrapAndParameterOnlyUnitsDoNotBreakHealthyChain() throws {
        let pixel = try pixels()
        var video: [UInt32] = [], resets = 0
        let stream = NativeVideoSnapshot(decode: { unit in
            guard unit.nals.contains(where: { ($0[0] >> 1) & 63 <= 31 }) else { return nil }
            video.append(unit.timestamp); return pixel
        }, resetDecoder: { resets += 1 })
        defer { stream.close() }
        for (sequence, timestamp, type): (UInt16, UInt32, UInt8) in [(1, .max - 1, 20), (2, .max - 1, 32), (3, 2, 1)] {
            stream.receive(packet(sequence, timestamp: timestamp, type: type), at: ProcessInfo.processInfo.systemUptime)
            idle(stream)
        }
        XCTAssertEqual(video, [.max - 1, 2])
        XCTAssertEqual(stream.status()["timestampRejections"] as? Int, 0)
        XCTAssertEqual(resets, 0)
    }
    func testWithheldPictureClearsOldPixelsAndStillAdvancesTimestamp() throws {
        let pixel = try pixels()
        var video: [UInt32] = []
        let stream = NativeVideoSnapshot(decode: { unit in
            video.append(unit.timestamp)
            return unit.timestamp == 2 ? nil : pixel
        }, resetDecoder: {})
        defer { stream.close() }
        let start = ProcessInfo.processInfo.systemUptime
        stream.receive(packet(1, timestamp: 1), at: start)
        XCTAssertNotNil(try stream.frame(after: start, timeout: 0.4, cancellation: NativeCancellation()))
        idle(stream)
        stream.receive(packet(2, timestamp: 2, type: 1), at: ProcessInfo.processInfo.systemUptime)
        idle(stream)
        XCTAssertNil(try stream.frame(after: start, timeout: 0, cancellation: NativeCancellation()))
        stream.receive(packet(3, timestamp: 2, type: 1), at: ProcessInfo.processInfo.systemUptime)
        idle(stream)
        XCTAssertEqual(video, [1, 2], "A withheld picture is still part of the reference timeline")
        XCTAssertEqual(stream.status()["timestampRejections"] as? Int, 1)
    }

}
