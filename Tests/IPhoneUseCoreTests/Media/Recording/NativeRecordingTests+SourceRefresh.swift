import XCTest
import AVFoundation
import CoreVideo
import Darwin
@testable import IPhoneUseCore

extension NativeRecordingTests {
    func testStaticSourceRefreshKeepsOneFileAndDeadlineWithNewTimestampEpoch() throws {
        for scenario in ["same", "rotation", "cancelled", "deadline", "clock"] {
            let dir = try root(), units = try fixture(dir), clock = RecordingTestClock()
            let old = RecordingSource(), replacement = RecordingSource()
            let first = try cache(old, units: units, at: 98)
            let next = try cache(replacement, units: units, at: 104)
            defer { first.close(); next.close() }
            let recorder = NativeStreamRecording(root: dir, now: clock.now)
            defer { _ = recorder.close() }
            let start = try recorder.start(
                duration: 20, receiver: old, mediaID: "old", rotation: "rot0", snapshots: first)
            let id = try XCTUnwrap(start["recordingID"] as? String)
            XCTAssertEqual(recorder.status()["state"] as? String, "recording")
            clock.set(102)
            let refresh = {
                try recorder.refreshSharedSource {
                    // The old stream really closes; the recorder must not treat
                    // that scoped teardown as an unexpected source failure.
                    old.setHealthy(false); first.close()
                    clock.set(scenario == "deadline" ? 121 : 104)
                    if scenario == "cancelled" { throw IPhoneUseError("native_cancelled", "cancelled") }
                    if scenario == "clock" { replacement.configuration["RTPClockRate"] = Int32(90000) }
                    return NativeStreamRecording.SharedSource(
                        receiver: replacement, snapshots: next,
                        mediaID: "replacement", rotation: scenario == "rotation" ? "rot90" : "rot0",
                        geometryChanged: scenario == "rotation")
                }
            }
            if ["cancelled", "deadline", "clock"].contains(scenario) {
                XCTAssertThrowsError(try refresh())
            } else {
                XCTAssertEqual(try refresh(), scenario == "rotation")
            }
            clock.set(108)
            let result = try recorder.stop(id: id)
            XCTAssertEqual(result["recordingID"] as? String, id)
            XCTAssertEqual(result["path"] as? String, start["path"] as? String)
            XCTAssertEqual(result["fileValidated"] as? Bool, ["same", "rotation"].contains(scenario))
            try verifyRefreshResult(result, scenario: scenario)
        }
    }

    func testColdEncoderPreparationDoesNotSubscribeOrConsumeRecordingDuration() throws {
        let dir = try root(), units = try fixture(dir), source = RecordingSource(),
            clock = RecordingTestClock()
        let snapshots = fixtureSnapshots()
        defer { snapshots.close() }
        let preparation = DispatchSemaphore(value: 0),
            delivered = expectation(description: "preview continues during preparation")
        source.setVideoHandler { snapshots.receive($0, at: clock.now()) }
        clock.set(98)
        DispatchQueue.global().async {
            self.packets(
                units, to: source,
                beforeUnit: { unit in
                    if unit.timestamp == units[1].timestamp {
                        XCTAssertEqual(preparation.wait(timeout: .now() + 3), .success)
                    }
                })
            delivered.fulfill()
        }
        let deadline = Date().addingTimeInterval(2)
        while snapshots.previewFrame() == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertNotNil(snapshots.previewFrame())
        clock.set(100)
        let recorder = NativeStreamRecording(
            root: dir, now: clock.now,
            makeWriter: { url, scale, orientation in
                NativeVideoWriter(
                    url: url, timescale: scale, orientation: orientation,
                    beforeEncoderSetup: {
                        clock.set(101); preparation.signal()
                        let deadline = Date().addingTimeInterval(2)
                        while snapshots.status()["decodedFrames"] as? Int != units.count, Date() < deadline {
                            Thread.sleep(forTimeInterval: 0.005)
                        }
                        XCTAssertEqual(snapshots.status()["decodedFrames"] as? Int, units.count)
                        clock.set(102)
                    })
            })
        defer { _ = recorder.close() }
        let started = try recorder.start(
            duration: 30, receiver: source, mediaID: "cold", rotation: "rot0", snapshots: snapshots)
        wait(for: [delivered], timeout: 3)
        XCTAssertEqual(recorder.status()["state"] as? String, "recording")
        clock.set(104)
        let result = try recorder.stop(id: XCTUnwrap(started["recordingID"] as? String))
        XCTAssertEqual(result["state"] as? String, "completed")
        XCTAssertEqual(
            result["writtenFrames"] as? Int, 1, "Only the current seed is admitted after preparation")
        XCTAssertEqual(result["elapsedSeconds"] as? Double, 2)
        XCTAssertEqual(result["initialCachedFrameAgeSeconds"] as? Double, 1)
        XCTAssertEqual(source.keyframeRequests, 0)
    }

    func testMissingSharedFrameStillWaitsWithoutTakingOverPacketHandler() throws {
        let source = RecordingSource(), snapshots = NativeVideoSnapshot()
        defer { snapshots.close() }
        source.setVideoHandler { _ in }
        let recorder = NativeStreamRecording(root: try root())
        defer { _ = recorder.close() }
        let result = try recorder.start(
            duration: 2, receiver: source, mediaID: "empty", rotation: "rot0", snapshots: snapshots)
        XCTAssertEqual(result["state"] as? String, "waiting_for_frame")
        XCTAssertTrue(recorder.isActive)
        XCTAssertTrue(source.attached)
    }

    func testSharedDecodedBurstKeepsRTPSpacingWhenReceiveTimesQuantizeTogether() throws {
        let dir = try root(), units = try fixture(dir), source = RecordingSource(),
            clock = RecordingTestClock()
        let snapshots = fixtureSnapshots()
        defer { snapshots.close() }
        let recorder = NativeStreamRecording(root: dir, now: clock.now)
        defer { _ = recorder.close() }
        var id: String?, receivedAt = 98.0
        source.setVideoHandler { snapshots.receive($0, at: receivedAt) }
        packets(
            units, to: source,
            beforeUnit: { unit in
                if unit.timestamp == units[1].timestamp {
                    let deadline = Date().addingTimeInterval(2)
                    while snapshots.previewFrame() == nil, Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.005)
                    }
                    XCTAssertNotNil(snapshots.previewFrame())
                    id =
                        try? recorder.start(
                            duration: 30, receiver: source, mediaID: "burst", rotation: "rot0",
                            snapshots: snapshots)[
                            "recordingID"] as? String
                    receivedAt = 101
                }
            })
        let deadline = Date().addingTimeInterval(2)
        while snapshots.status()["decodedFrames"] as? Int != units.count, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(snapshots.status()["decodedFrames"] as? Int, units.count)
        clock.set(104)
        let result = try recorder.stop(id: XCTUnwrap(id))
        XCTAssertEqual(result["state"] as? String, "completed")
        XCTAssertEqual(result["writtenFrames"] as? Int, units.count)
        XCTAssertEqual((try XCTUnwrap(result["mediaSpanSeconds"] as? Double)), 2.8, accuracy: 0.001)
        XCTAssertEqual(source.keyframeRequests, 0)
    }
    private func cache(_ source: RecordingSource, units: [NativeVideoAccessUnit], at time: Double) throws
        -> NativeVideoSnapshot {
        let snapshots = fixtureSnapshots()
        source.setVideoHandler { snapshots.receive($0, at: time) }
        self.packets([units[0]], to: source)
        let deadline = Date().addingTimeInterval(2)
        while snapshots.previewFrame() == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        XCTAssertNotNil(snapshots.previewFrame())
        return snapshots
    }

    private func verifyRefreshResult(_ result: [String: Any], scenario: String) throws {
        if scenario == "same" {
            XCTAssertEqual(result["elapsedSeconds"] as? Double, 8)
            XCTAssertEqual(result["writtenFrames"] as? Int, 2)
            let video = try XCTUnwrap(result["video"] as? [String: Any])
            XCTAssertEqual((try XCTUnwrap(video["durationSeconds"] as? Double)), 8, accuracy: 0.01)
            let refreshes = try XCTUnwrap(result["sourceRefreshes"] as? [[String: Any]])
            XCTAssertEqual(refreshes.count, 1)
            XCTAssertEqual(refreshes[0]["durationSeconds"] as? Double, 2)
            XCTAssertEqual(result["mediaSessionID"] as? String, "replacement")
        } else if scenario == "rotation" {
            XCTAssertEqual(result["stopReason"] as? String, "display_changed")
            XCTAssertEqual(result["writtenFrames"] as? Int, 1, "Never append a differently oriented source")
        } else {
            XCTAssertEqual(result["stopReason"] as? String, "media_refresh_failed")
        }
    }

}
