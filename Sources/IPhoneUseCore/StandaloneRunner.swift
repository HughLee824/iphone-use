import Foundation

// Deployment belongs to setup. Connecting never installs, re-signs, changes
// network permissions, or takes over an already-running test process.
final class StandaloneRunner {
    typealias Read = ([String], [String], [String: String]?) throws -> [String: Any]
    private let read: Read
    private(set) var process: NativeAppProcess?
    private(set) var launchRequested = false
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    init(read: @escaping Read) { self.read = read }

    static func bundleID(manifest: URL) throws -> String {
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: manifest), format: nil)
        guard let dictionary = value as? [String: Any] else {
            throw IPhoneUseError("runner_manifest_invalid", "Expected an XCTest manifest dictionary")
        }
        let configurations = dictionary["TestConfigurations"] as? [[String: Any]] ?? []
        var targets = configurations.flatMap { $0["TestTargets"] as? [[String: Any]] ?? [] }
            .filter { $0["BlueprintName"] as? String == "IPhoneUseTests" }
        if let target = dictionary["IPhoneUseTests"] as? [String: Any] { targets.append(target) }
        guard targets.count == 1, targets[0]["IsUITestBundle"] as? Bool == true,
              let bundle = targets[0]["TestHostBundleIdentifier"] as? String else {
            throw IPhoneUseError("runner_manifest_invalid", "Expected one IPhoneUseTests UI Runner with a host bundle identifier")
        }
        try RunnerBuild.validateSigning(team: nil, bundleID: bundle)
        return bundle
    }

    func start(bundle: String, token: String) throws -> NativeAppProcess {
        let apps = try read(["device", "info", "apps", "--include-all-apps"], [], nil)
        let app: URL
        do { app = try NativeAppProcess.appURL(bundle: bundle, result: apps) }
        catch let error as IPhoneUseError where error.code == "app_not_installed" {
            throw IPhoneUseError("runner_not_installed", "Runner is not installed. Run setup to deploy the signed Runner; connect never installs automatically")
        }
        guard try NativeAppProcess.target(in: processes(), app: app) == nil else {
            throw IPhoneUseError("runner_already_running", "The selected Runner is already running; release its owning session before connecting")
        }
        launchRequested = true
        let response = try read(["device", "process", "launch", "--no-activate"], [bundle],
            ["IPHONE_USE_SESSION_TOKEN": token, "IPHONE_USE_LISTEN_HOST": "127.0.0.1", "IPHONE_USE_HOST_MANAGED": "1"])
        guard let row = response["process"] as? [String: Any] else {
            throw IPhoneUseError("runner_launch_unconfirmed", "Runner launch did not return a process identity; inspect the device before retrying")
        }
        let launched = NativeAppProcess(pid: try NativeAppProcess.identifier(row["processIdentifier"]),
                                        executable: try NativeAppProcess.fileURL(row["executable"]))
        guard launched.executable.deletingLastPathComponent().path == app.path else {
            throw IPhoneUseError("runner_launch_unconfirmed", "Launch identity did not match the installed Runner; no unrelated process will be terminated")
        }
        process = launched
        guard let options = response["launchOptions"] as? [String: Any], options["activatedWhenStarted"] as? Bool == false else {
            throw IPhoneUseError("runner_background_launch_unconfirmed", "CoreDevice did not confirm background launch")
        }
        return launched
    }

    private func processes() throws -> [NativeAppProcess] {
        try NativeAppProcess.list(read(["device", "info", "processes"], [], nil))
    }

    func isRunning() throws -> Bool {
        guard let process else { return false }
        return try processes().contains(process)
    }

    func stop() -> [String: Any] {
        guard let owned = process else {
            return ["runnerProcessExited": !launchRequested, "runnerLaunchUnconfirmed": launchRequested]
        }
        var result: [String: Any] = ["runnerPid": owned.pid, "runnerProcessExited": false, "terminationRequested": false]
        do {
            let deadline = now() + 3
            while try isRunning(), now() < deadline { sleep(0.2) }
            if try isRunning() {
                // Recheck exact PID/path before signaling; never kill a newly
                // launched replacement. CoreDevice's PID-only signal has the same
                // final lookup-to-signal race as NativeAppLifecycle.
                guard try processes().contains(owned) else { result["runnerProcessExited"] = true; return result }
                result["terminationRequested"] = true
                _ = try read(["device", "process", "terminate", "--pid", String(owned.pid)], [], nil)
                result["terminationAcknowledged"] = true
                let deadline = now() + 3
                while try isRunning(), now() < deadline { sleep(0.2) }
            }
            result["runnerProcessExited"] = try !isRunning()
        } catch {
            result["cleanupError"] = String(describing: error)
        }
        if result["runnerProcessExited"] as? Bool == true { process = nil }
        return result
    }
}
