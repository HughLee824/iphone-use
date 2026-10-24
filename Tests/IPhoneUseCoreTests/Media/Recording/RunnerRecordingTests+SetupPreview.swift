import XCTest
@testable import IPhoneUseCore

extension RunnerRecordingTests {
    func testSetupPreviewCollisionReportsWarningWithoutOpeningMedia() throws {
        let occupied = try NativePreview(port: 0)
        defer { occupied.close() }
        let port = try XCTUnwrap(occupied.status()["port"] as? Int)
        for optional in [true, false] {
            let directory = try root()
            let config = HostConfiguration(
                session: "s" + String(repeating: "a", count: 32), device: "fixture", xctestrun: "fixture",
                idleTimeoutSeconds: 180, startupPreviewPort: port, startupPreviewOptional: optional)
            let backend = XCTestBackend(config: config, paths: SessionPaths(directory: directory))
            var starts = 0
            let owner = RunnerNativeRecording(root: directory, cancellation: NativeCancellation()) {
                starts += 1
                return RunnerRecordingConnectionStub()
            }
            defer { _ = owner.close() }
            backend.recording = owner
            if optional {
                XCTAssertNoThrow(try backend.startConfiguredPreview())
                let progress = try jsonObject(
                    Data(contentsOf: directory.appendingPathComponent("connection-progress.json")))
                XCTAssertNotNil(progress["previewError"] as? String)
                XCTAssertEqual(progress["requiresUserAction"] as? Bool, false)
                XCTAssertTrue(progress["previewURL"] is NSNull)
            } else {
                XCTAssertThrowsError(try backend.startConfiguredPreview()) {
                    XCTAssertEqual(($0 as? IPhoneUseError)?.code, "preview_port_in_use")
                }
            }
            XCTAssertEqual(starts, 0)
        }
    }
}
