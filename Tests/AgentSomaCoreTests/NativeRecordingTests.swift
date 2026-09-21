import XCTest
import AVFoundation
import CoreVideo
@testable import AgentSomaCore

final class NativeRecordingTests: XCTestCase {
    func testCapabilityAndDurationFailClosed() throws {
        XCTAssertFalse(NativeScreenRecording.supported(by: [:]))
        XCTAssertFalse(NativeScreenRecording.supported(by: ["capabilities": [["featureIdentifier": "com.apple.coredevice.feature.capturescreenshot"]]]))
        XCTAssertTrue(NativeScreenRecording.supported(by: ["capabilities": [["featureIdentifier": "com.apple.coredevice.feature.screenrecording"]]]))
        for value: Any in [true, 0, -1, 301, Double.infinity, "5"] {
            XCTAssertThrowsError(try NativeScreenRecording.duration(["duration": value]))
        }
        XCTAssertEqual(try NativeScreenRecording.duration(["duration": 5]), 5)
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-test-\(UUID().uuidString)")
        try SessionPaths.secureDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func recorder(root: URL, script: String, grace: Double = 1,
                          validate: @escaping (URL) throws -> [String: Any] = { _ in ["decodedFrames": 2] }) -> NativeScreenRecording {
        NativeScreenRecording(root: root, device: "test-device", grace: grace, configure: { process, movie, _, report in
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script, "recording-test", movie.path, report.path]
        }, validate: validate)
    }

    private func complete(_ recorder: NativeScreenRecording, timeout: Double = 5) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let value = recorder.status()
            if ["completed", "failed"].contains(value["state"] as? String ?? "") { return value }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("Recording did not terminate")
        return recorder.status()
    }

    func testTimedCompletionPreservesArtifactsAndDoesNotEquateExitWithVideo() throws {
        let dir = try root()
        let recorder = recorder(root: dir, script: "printf invalid > \"$1\"", validate: NativeRecordingValidation.inspect)
        defer { _ = recorder.close() }
        let started = try recorder.start(duration: 2)
        XCTAssertEqual(started["fileValidated"] as? Bool, false)
        let result = try complete(recorder)
        XCTAssertEqual(result["state"] as? String, "failed")
        XCTAssertEqual(result["exitCode"] as? Int32, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: started["path"] as! String))
        XCTAssertEqual(try recorder.stop(id: started["recordingID"] as! String)["state"] as? String, "failed")
    }

    func testOwnedStopIsIdempotentAndCannotStopNewRecording() throws {
        let dir = try root()
        let recorder = recorder(root: dir, script: "trap 'exit 0' INT; while :; do sleep 0.1; done")
        defer { _ = recorder.close() }
        let first = try recorder.start(duration: 30)
        Thread.sleep(forTimeInterval: 0.15) // Allow the host fixture to install its signal handler.
        XCTAssertThrowsError(try recorder.start(duration: 30))
        XCTAssertThrowsError(try recorder.stop(id: UUID().uuidString))
        let stopped = try recorder.stop(id: first["recordingID"] as! String)
        XCTAssertEqual(stopped["state"] as? String, "completed")
        XCTAssertEqual(stopped["forced"] as? Bool, false)
        let second = try recorder.start(duration: 30)
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertNotEqual(first["recordingID"] as? String, second["recordingID"] as? String)
        _ = try recorder.stop(id: first["recordingID"] as! String)
        XCTAssertTrue(recorder.isActive)
        XCTAssertEqual(recorder.status()["recordingID"] as? String, second["recordingID"] as? String)
        let cleanup = recorder.close()
        XCTAssertEqual(cleanup["recordingProcessExited"] as? Bool, true)
        XCTAssertEqual((cleanup["recording"] as? [String: Any])?["stopReason"] as? String, "session_closed")
        XCTAssertThrowsError(try recorder.start(duration: 1))
    }

    func testForcedExitNeverClaimsCompleteEvenWithDecodableArtifact() throws {
        let recorder = recorder(root: try root(), script: "trap '' INT TERM; while :; do sleep 0.1; done", grace: 0.1)
        let start = try recorder.start(duration: 30)
        Thread.sleep(forTimeInterval: 0.15)
        let result = try recorder.stop(id: start["recordingID"] as! String)
        XCTAssertEqual(result["state"] as? String, "failed")
        XCTAssertEqual(result["forced"] as? Bool, true)
        XCTAssertEqual(result["processExited"] as? Bool, true)
        XCTAssertEqual(recorder.close()["recordingProcessExited"] as? Bool, true)
    }

    func testPrematureNaturalCompletionIsNotAcceptedForLongRecording() throws {
        let recorder = recorder(root: try root(), script: "exit 0", validate: { _ in ["durationSeconds": 1.0, "decodedFrames": 10] })
        defer { _ = recorder.close() }
        _ = try recorder.start(duration: 30)
        let result = try complete(recorder)
        XCTAssertEqual(result["state"] as? String, "failed")
        XCTAssertEqual((result["error"] as? [String: Any])?["code"] as? String, "recording_duration_mismatch")
    }

    func testAppleUnsupportedFailureIsReportedWithoutRetry() throws {
        let recorder = recorder(root: try root(), script: """
        printf '%s' '{"error":{"code":1001,"domain":"com.apple.dt.CoreDeviceError","userInfo":{"CapabilityFeatureIdentifier":{"string":"com.apple.coredevice.feature.screenrecording"}}}}' > "$2"
        exit 1
        """)
        defer { _ = recorder.close() }
        let start = try recorder.start(duration: 1)
        let result = try complete(recorder)
        XCTAssertEqual((result["error"] as? [String: Any])?["code"] as? String, "native_recording_unsupported")
        _ = try recorder.stop(id: start["recordingID"] as! String)
        XCTAssertEqual(recorder.status()["recordingID"] as? String, start["recordingID"] as? String)
    }

    func testCompleteMovieIsDecodedAndTruncationRejected() throws {
        let dir = try root(), url = dir.appendingPathComponent("fixture.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            let deadline = Date().addingTimeInterval(2)
            while !input.isReadyForMoreMediaData, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 20), CVPixelBufferGetBytesPerRow(pixels) * 64)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        input.markAsFinished()
        let finished = expectation(description: "movie finished")
        writer.finishWriting { finished.fulfill() }; wait(for: [finished], timeout: 5)
        XCTAssertEqual(writer.status, .completed)
        let result = try NativeRecordingValidation.inspect(url)
        XCTAssertEqual(result["decodedFrames"] as? Int, 10)
        XCTAssertEqual(result["width"] as? Int, 64)
        let recorder = NativeScreenRecording(root: dir.appendingPathComponent("owned"), device: "fixture", configure: { process, movie, _, _ in
            process.executableURL = URL(fileURLWithPath: "/bin/cp")
            process.arguments = [url.path, movie.path]
        })
        defer { _ = recorder.close() }
        _ = try recorder.start(duration: 1)
        let completed = try complete(recorder)
        XCTAssertEqual(completed["state"] as? String, "completed")
        XCTAssertEqual(completed["fileValidated"] as? Bool, true)
        XCTAssertEqual((completed["video"] as? [String: Any])?["decodedFrames"] as? Int, 10)
        let broken = dir.appendingPathComponent("truncated.mp4")
        try Data(contentsOf: url).prefix(100).write(to: broken)
        XCTAssertThrowsError(try NativeRecordingValidation.inspect(broken))
    }
}
