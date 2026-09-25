import XCTest

final class RecordingProbeTests: XCTestCase {
    @MainActor
    func testOwnedRecordingExport() async throws {
        guard ProcessInfo.processInfo.environment["IPHONE_USE_RECORDING_PROBE"] == "1" else {
            throw XCTSkip("Explicitly opt in to the controlled Probe recording test")
        }
        let app = XCUIApplication(bundleIdentifier: "com.iphone-use.native-text-probe")
        guard app.state == .runningForeground else {
            XCTFail("Controlled Probe must already be in the foreground; no recording started")
            return
        }
        let done = expectation(description: "own recording stopped and attached")
        var completed = false
        IPhoneUseRecordingProbe.run { facts in
            DispatchQueue.main.async {
                let data = try! JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys])
                print("IPHONE_USE_RECORDING_PROBE " + String(decoding: data, as: UTF8.self))
                completed = facts["stopAcknowledged"] as? Bool == true && facts["error"] == nil
                done.fulfill()
            }
        }
        await fulfillment(of: [done], timeout: 20)
        guard completed else { XCTFail("Recording start/owned stop failed; inspect facts"); return }
        // Host export attempts during this window distinguish live export from
        // results only available after the test process has finished.
        print("IPHONE_USE_RECORDING_EXPORT_WINDOW")
        try await Task.sleep(nanoseconds: 45_000_000_000)
    }
}
