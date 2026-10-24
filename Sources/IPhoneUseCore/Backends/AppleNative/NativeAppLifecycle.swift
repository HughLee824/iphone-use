import Foundation
import CoreFoundation

// Exact installed-app directory matching, never process-name or substring matching.
// CoreDevice exposes PID/path but no process birth token; its PID-only terminate
// cannot eliminate the final lookup-to-signal race. Recheck immediately before send.
struct NativeAppProcess: Equatable {
    let pid: Int
    let executable: URL

    static func fileURL(_ value: Any?) throws -> URL {
        guard let text = value as? String, let url = URL(string: text), url.isFileURL,
            url.host == nil || url.host == "" || url.host == "localhost",
            url.query == nil, url.fragment == nil, url.path.hasPrefix("/")
        else {
            throw IPhoneUseError(
                "native_process_identity_invalid", "Apple did not return a local absolute file URL")
        }
        return url.standardizedFileURL
    }
    static func identifier(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue > 1, number.doubleValue <= Double(Int32.max),
            number.doubleValue == Double(number.intValue)
        else {
            throw IPhoneUseError("native_process_identity_invalid", "Apple did not return a valid app PID")
        }
        return number.intValue
    }
    static func appURL(bundle: String, result: [String: Any]) throws -> URL {
        try AppCatalog(result).requireInstalled(bundle)
        guard let apps = result["apps"] as? [[String: Any]] else {
            throw IPhoneUseError("invalid_discovery", "CoreDevice did not return an installed app list")
        }
        let matches = apps.filter { $0["bundleIdentifier"] as? String == bundle }
        guard matches.count == 1 else {
            throw IPhoneUseError(
                "native_app_ambiguous", "Bundle ID did not identify exactly one installed app")
        }
        let url = try fileURL(matches[0]["url"])
        guard url.pathExtension == "app" else {
            throw IPhoneUseError("native_process_identity_invalid", "Target is not an app bundle")
        }
        return url
    }
    static func list(_ result: [String: Any]) throws -> [Self] {
        guard let rows = result["runningProcesses"] as? [[String: Any]] else {
            throw IPhoneUseError("native_process_list_invalid", "Apple did not return a running process list")
        }
        var seen = Set<Int>()
        return try rows.map { row in
            // launchd is present in the full list, but can never be an app target.
            let raw = row["processIdentifier"]
            let pid = (raw as? NSNumber)?.intValue == 1 ? 1 : try identifier(raw)
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue == Double(pid), seen.insert(pid).inserted
            else {
                throw IPhoneUseError("native_process_list_invalid", "Invalid or duplicate process identity")
            }
            return Self(pid: pid, executable: try fileURL(row["executable"]))
        }
    }
    static func target(in processes: [Self], app: URL) throws -> Self? {
        let matches = processes.filter { $0.executable.deletingLastPathComponent().path == app.path }
        guard matches.count <= 1 else {
            throw IPhoneUseError(
                "native_app_ambiguous", "Multiple main-process candidates; no process was selected")
        }
        if let match = matches.first { _ = try identifier(match.pid) }
        return matches.first
    }
}

struct NativeAppLifecycle {
    let read: ([String], [String], TimeInterval) throws -> [String: Any]
    let checkCancellation: () throws -> Void
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    func run(bundle: String, relaunch: Bool) throws -> [String: Any] {
        var attempt = Attempt(lifecycle: self, bundle: bundle, relaunch: relaunch)
        return try attempt.run(bundle: bundle, relaunch: relaunch)
    }

    private struct Attempt {
        let lifecycle: NativeAppLifecycle
        let deadline: TimeInterval
        var mutated = false
        var facts: [String: Any]

        init(lifecycle: NativeAppLifecycle, bundle: String, relaunch: Bool) {
            self.lifecycle = lifecycle; deadline = lifecycle.now() + 30
            facts = [
                "bundleId": bundle, "operation": relaunch ? "relaunch" : "terminate",
                "terminationRequested": false, "terminationAcknowledged": false,
                "oldProcessAbsentConfirmed": false,
                "launchRequested": false, "launchAcknowledged": false, "newProcessObserved": false,
                "foregroundConfirmed": false, "verificationStatus": "not_checked",
                "automaticReplayAllowed": false
            ]
        }
        func check() throws {
            try lifecycle.checkCancellation()
            guard lifecycle.now() < deadline else {
                throw IPhoneUseError("native_app_lifecycle_timeout", "App lifecycle deadline exceeded")
            }
        }
        func request(_ args: [String], tail: [String] = []) throws -> [String: Any] {
            try check()
            return try lifecycle.read(args, tail, min(5, deadline - lifecycle.now()))
        }
        func processes() throws -> [NativeAppProcess] {
            try NativeAppProcess.list(request(["device", "info", "processes"]))
        }
        mutating func run(bundle: String, relaunch: Bool) throws -> [String: Any] {
            do {
                let app = try NativeAppProcess.appURL(
                    bundle: bundle, result: request(["device", "info", "apps", "--include-all-apps"]))
                let old = try NativeAppProcess.target(in: processes(), app: app)
                facts["alreadyStopped"] = old == nil
                facts["previousPID"] = old?.pid as Any? ?? NSNull()
                try terminate(old, app: app)
                if relaunch { try launch(bundle: bundle, app: app, old: old) }
                facts["transportStatus"] = mutated ? "acknowledged" : "not_needed"
                return facts
            } catch {
                let code = (error as? IPhoneUseError)?.code ?? "native_app_lifecycle_failed"
                facts["failureCode"] = code
                throw ActionFailure(
                    code: code,
                    description: "App lifecycle stopped: \(error). No lifecycle command was replayed.",
                    possiblyExecuted: mutated,
                    requiresObservation: mutated || code == "native_app_process_changed",
                    result: facts)
            }
        }

        mutating func terminate(_ old: NativeAppProcess?, app: URL) throws {
            if let old {
                let current = try NativeAppProcess.target(in: processes(), app: app)
                guard current == old else {
                    throw IPhoneUseError(
                        "native_app_process_changed",
                        "App process changed before termination; inspect before deciding again")
                }
                try check()
                facts["terminationRequested"] = true
                facts["terminationSignal"] = "SIGTERM"
                mutated = true
                _ = try request(["device", "process", "terminate", "--pid", String(old.pid)])
                facts["terminationAcknowledged"] = true
                let exitDeadline = min(deadline, lifecycle.now() + 5)
                while true {
                    let rows = try processes()
                    let current = try NativeAppProcess.target(in: rows, app: app)
                    if !rows.contains(old) {
                        facts["oldProcessAbsentConfirmed"] = true
                        guard current == nil else {
                            throw IPhoneUseError(
                                "native_app_process_changed",
                                "App restarted externally; no further termination or launch was sent")
                        }
                        break
                    }
                    guard lifecycle.now() < exitDeadline else {
                        throw IPhoneUseError(
                            "native_app_exit_unconfirmed",
                            "Termination was acknowledged but the old process is still listed")
                    }
                    lifecycle.sleep(0.1)
                }
            } else {
                facts["oldProcessAbsentConfirmed"] = true
            }
        }

        mutating func launch(bundle: String, app: URL, old: NativeAppProcess?) throws {
            // Do not activate a replacement that appeared since the exit check.
            guard try NativeAppProcess.target(in: processes(), app: app) == nil else {
                throw IPhoneUseError(
                    "native_app_process_changed", "App appeared before launch; no launch was sent")
            }
            let installed = try NativeAppProcess.appURL(
                bundle: bundle, result: request(["device", "info", "apps", "--include-all-apps"]))
            guard installed == app else {
                throw IPhoneUseError("native_app_process_changed", "Installed app changed before launch")
            }
            try check()
            facts["launchRequested"] = true
            mutated = true
            let launch = try request(["device", "process", "launch", "--activate"], tail: [bundle])
            facts["launchAcknowledged"] = true
            guard let process = launch["process"] as? [String: Any] else {
                throw IPhoneUseError("native_app_launch_unconfirmed", "Launch reply has no process identity")
            }
            let pid = try NativeAppProcess.identifier(process["processIdentifier"])
            facts["newPID"] = pid
            let current = try NativeAppProcess.target(in: processes(), app: app)
            guard current?.pid == pid, pid != old?.pid else {
                throw IPhoneUseError(
                    "native_app_launch_unconfirmed",
                    "A new matching app process was not confirmed after launch")
            }
            facts["newProcessObserved"] = true
        }
    }
}
