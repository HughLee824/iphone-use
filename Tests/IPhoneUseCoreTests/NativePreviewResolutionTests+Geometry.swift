import XCTest
import CoreImage
@testable import IPhoneUseCore

extension NativePreviewResolutionTests {

    func testReducedGeometryPreservesFreshnessBarrierAndRejectsConflicts() throws {
        let buffer = try pixels(activeWidth: 32, activeHeight: 48)
        let reduced = NativeDecodedVideoFrame(
            pixels: buffer, nativeWidth: 48, nativeHeight: 96,
            activeWidth: 32, activeHeight: 48)
        let stream = NativeVideoSnapshot(decode: { _ in reduced }, resetDecoder: {})
        let receiver = try NativeRTPReceiver(
            deviceAddress: "::1", captureSnapshots: true, makeSnapshots: { stream })
        defer { receiver.close() }
        let start = ProcessInfo.processInfo.systemUptime
        stream.receive(geometryPacket(1, profile: 0x92), at: start)
        let frame = try XCTUnwrap(
            stream.frame(
                after: start, timeout: 0.4,
                includeReducedResolution: true, cancellation: NativeCancellation()))
        XCTAssertNoThrow(
            try NativeSnapshotImage.validateGeometry(
                frame, display: display("rot270"), allowReducedResolution: true))
        XCTAssertThrowsError(
            try NativeSnapshotImage.validateGeometry(
                frame, display: display("rot90"), allowReducedResolution: true))
        XCTAssertThrowsError(
            try stream.rejectConflictingGeometry(display("rot90")),
            "Reduced frames retain half-turn conflict evidence")
        XCTAssertNil(
            try receiver.snapshot(
                after: start, timeout: 0, includeReducedResolution: true,
                cancellation: NativeCancellation()),
            "The socket barrier must exclude already decoded reduced frames")
        XCTAssertNil(
            try stream.frame(
                after: frame.completedAt + 1, timeout: 0,
                includeReducedResolution: true, cancellation: NativeCancellation()))
        XCTAssertNil(try stream.frame(after: start, timeout: 0, cancellation: NativeCancellation()))
        // Broken references cannot leave geometry usable, even when the last
        // valid reduced frame was very recent.
        stream.receive(geometryPacket(2, timestamp: 1), at: ProcessInfo.processInfo.systemUptime)
        let done = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                stream.status()["pendingBytes"] as? Int == 0
            }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 2), .completed)
        XCTAssertEqual(stream.status()["timestampRejections"] as? Int, 1)
        XCTAssertNil(
            try stream.frame(
                after: start, timeout: 0, includeReducedResolution: true, cancellation: NativeCancellation()))
        stream.close()
        XCTAssertNil(
            try stream.frame(
                after: start, timeout: 0, includeReducedResolution: true, cancellation: NativeCancellation()))
    }
}
