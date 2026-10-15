import XCTest
@testable import IPhoneUseCore

final class StandaloneRunnerTests: XCTestCase {
    private let app = "file:///private/test/Runner.app/"
    private var row: [String: Any] { ["processIdentifier": 123, "executable": app + "Runner"] }
    private var apps: [String: Any] { ["apps": [["bundleIdentifier": "com.example.runner", "url": app]]] }

    func testBackgroundLaunchHasOnlyLoopbackAndSessionEnvironmentAndNeverInstalls() throws {
        var calls: [[String]] = []
        let runner = StandaloneRunner { args, tail, env in
            calls.append(args)
            switch args.prefix(3).joined(separator: " ") {
            case "device info apps": return self.apps
            case "device info processes": return ["runningProcesses": []]
            case "device process launch":
                XCTAssertEqual(args, ["device", "process", "launch", "--no-activate"])
                XCTAssertEqual(tail, ["com.example.runner"])
                XCTAssertEqual(env, ["IPHONE_USE_SESSION_TOKEN": "token", "IPHONE_USE_LISTEN_HOST": "127.0.0.1", "IPHONE_USE_HOST_MANAGED": "1"])
                return ["process": self.row, "launchOptions": ["activatedWhenStarted": false]]
            default: XCTFail("Unexpected mutation: \(args)"); return [:]
            }
        }
        XCTAssertEqual(try runner.start(bundle: "com.example.runner", token: "token").pid, 123)
        XCTAssertEqual(calls.count, 3)
    }

    func testMissingOrAlreadyRunningAppDoesNotLaunchOrInstall() {
        for installed in [false, true] {
            var launched = false
            let runner = StandaloneRunner { args, _, _ in
                if args.contains("apps") { return installed ? self.apps : ["apps": []] }
                if args.contains("processes") { return ["runningProcesses": [self.row]] }
                launched = true; return [:]
            }
            XCTAssertThrowsError(try runner.start(bundle: "com.example.runner", token: "token"))
            XCTAssertFalse(launched)
            XCTAssertFalse(runner.launchRequested)
            XCTAssertEqual(runner.stop()["runnerProcessExited"] as? Bool, true)
        }
    }

    func testCleanupNeverTerminatesReplacementPIDOrUnrelatedPath() throws {
        for replacement in [["processIdentifier": 124, "executable": app + "Runner"],
                            ["processIdentifier": 123, "executable": "file:///other.app/Runner"]] as [[String: Any]] {
            var started = false
            let runner = StandaloneRunner { args, _, _ in
                if args.contains("apps") { return self.apps }
                if args.contains("processes") { return ["runningProcesses": started ? [replacement] : []] }
                if args.contains("launch") { started = true; return ["process": self.row, "launchOptions": ["activatedWhenStarted": false]] }
                XCTFail("Must not terminate replacement"); return [:]
            }
            _ = try runner.start(bundle: "com.example.runner", token: "token")
            XCTAssertEqual(runner.stop()["runnerProcessExited"] as? Bool, true)
        }
    }

    func testCleanupConfirmsOwnedProcessExitAndReportsFailedTermination() throws {
        for fails in [false, true] {
            var started = false, stopped = false
            let runner = StandaloneRunner { args, _, _ in
                if args.contains("apps") { return self.apps }
                if args.contains("processes") { return ["runningProcesses": started && !stopped ? [self.row] : []] }
                if args.contains("launch") { started = true; return ["process": self.row, "launchOptions": ["activatedWhenStarted": false]] }
                XCTAssertEqual(args, ["device", "process", "terminate", "--pid", "123"])
                if fails { throw IPhoneUseError("test_failure", "Termination failed") }
                stopped = true; return [:]
            }
            var clock: Double = 0
            runner.now = { clock }; runner.sleep = { clock += $0 }
            _ = try runner.start(bundle: "com.example.runner", token: "token")
            XCTAssertEqual(runner.stop()["runnerProcessExited"] as? Bool, !fails)
        }
    }

    func testUncertainLaunchIsNotReplayedOrClaimedClean() {
        var launches = 0
        let runner = StandaloneRunner { args, _, _ in
            if args.contains("apps") { return self.apps }
            if args.contains("processes") { return ["runningProcesses": []] }
            launches += 1; throw IPhoneUseError("timeout", "Launch reply lost")
        }
        XCTAssertThrowsError(try runner.start(bundle: "com.example.runner", token: "token"))
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(runner.stop()["runnerProcessExited"] as? Bool, false)
    }

    func testManifestRequiresUnambiguousValidRunnerIdentity() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let target: [String: Any] = ["BlueprintName": "IPhoneUseTests", "IsUITestBundle": true, "TestHostBundleIdentifier": "com.example.runner"]
        for layout: [String: Any] in [["IPhoneUseTests": target], ["TestConfigurations": [["TestTargets": [target]]]]] {
            try PropertyListSerialization.data(fromPropertyList: layout, format: .xml, options: 0).write(to: file)
            XCTAssertEqual(try StandaloneRunner.bundleID(manifest: file), "com.example.runner")
        }
        for layout: [String: Any] in [[:], ["IPhoneUseTests": target, "TestConfigurations": [["TestTargets": [target]]]],
                                      ["IPhoneUseTests": ["IsUITestBundle": true, "TestHostBundleIdentifier": "com.example.runner\n"]]] {
            try PropertyListSerialization.data(fromPropertyList: layout, format: .xml, options: 0).write(to: file)
            XCTAssertThrowsError(try StandaloneRunner.bundleID(manifest: file))
        }
    }
}
