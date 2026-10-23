import Foundation
import AppleNativeBridge
import Darwin

// Match complete messages from Apple's testmanagerd, not arbitrary log text,
// elapsed time, UI inactivity or media failures. Raw device logs never leave
// this helper and are not persisted.
enum RunnerAuthorizationEvent: Equatable {
    case client(manager: Int, runner: Int)
    case required(manager: Int)
    case authenticated(manager: Int)
    case enabled(manager: Int)
    case disabled(manager: Int)

    static func parse(_ line: String) -> RunnerAuthorizationEvent? {
        guard line.contains(" testmanagerd") else { return nil }
        let pattern =
            #"^\w{3} +\d{1,2} \d{2}:\d{2}:\d{2}(?:\.\d+)? (?:[^\s\[\]]+ )?"#
            + #"testmanagerd(?:\(AutomationMode\))?\[(\d+)\] <(?:Notice|Info|Debug)>: (.+)$"#
        guard let match = line.range(of: pattern, options: .regularExpression),
            match == line.startIndex..<line.endIndex,
            let start = line.range(of: "["),
            let end = line.range(of: "]", range: start.upperBound..<line.endIndex),
            let manager = Int(line[start.upperBound..<end.lowerBound]),
            let separator = line.range(of: ">: ")
        else { return nil }
        let message = String(line[separator.upperBound...])
        if message == "Writer daemon requires authentication to enable automation mode." {
            return .required(manager: manager)
        }
        if message == "User authenticated, forwarding authorization to writer daemon." {
            return .authenticated(manager: manager)
        }
        if message == "Finished enabling Automation Mode" { return .enabled(manager: manager) }
        if message == "Finished disabling Automation Mode" { return .disabled(manager: manager) }
        if message.hasPrefix("Added Automation Mode client <XCTestSession: "),
            let range = message.range(of: #"> pid (\d+)\. Total clients: \d+$"#, options: .regularExpression),
            let runner = Int(message[range].dropFirst(6).split(separator: ".")[0]) {
            return .client(manager: manager, runner: message.hasSuffix("Total clients: 1") ? runner : -1)
        }
        return nil
    }

    var wire: [String: Any] {
        switch self {
        case let .client(manager, runner): return ["kind": "client", "manager": manager, "runner": runner]
        case let .required(manager): return ["kind": "required", "manager": manager]
        case let .authenticated(manager): return ["kind": "authenticated", "manager": manager]
        case let .enabled(manager): return ["kind": "enabled", "manager": manager]
        case let .disabled(manager): return ["kind": "disabled", "manager": manager]
        }
    }
}

public enum RunnerAuthorizationLog {
    public static func run(device: String) throws {
        func emit(_ value: [String: Any]) {
            if var data = try? jsonData(value) { data.append(10); FileHandle.standardOutput.write(data) }
        }
        var error: NSError?
        _ = ASReadDeviceLog(
            device, { emit(["kind": "monitor_ready"]) },
            { line in
                if let event = RunnerAuthorizationEvent.parse(line) { emit(event.wire) }
            }, &error)
        throw error
            ?? IPhoneUseError("authorization_monitor_unavailable", "Live authorization evidence unavailable")
    }
}

// Independent of the device command/encoding queues so a blocked XCTest call
// cannot prevent an already-open page from reporting a confirmed prompt.
final class RunnerAuthorization {
    private let lock = NSLock()
    private let file: URL
    private var process: Process?
    private var pipe: Pipe?
    private var buffer = Data()
    private var pending: [[String: Any]] = []
    private var runnerPID: Int?
    private var managerPID: Int?
    private var monitoring = false
    private var phase = "starting"
    private var authorization = "unknown"
    private var previewURL: String?
    private var failure: String?
    private var stopped = false

    init(directory: URL) { file = directory.appendingPathComponent("connection-progress.json") }

    func start(device: String) {
        let task = Process(), output = Pipe()
        task.executableURL = Bundle.main.executableURL
        task.arguments = ["_authorization-monitor", "--device", device]
        task.standardInput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        task.standardOutput = output
        process = task; pipe = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard !self.stopped else { return }
            if data.isEmpty {
                self.consume(["kind": "monitor_unavailable"])
                handle.readabilityHandler = nil; return
            }
            self.buffer.append(data)
            while let newline = self.buffer.firstIndex(of: 10) {
                let line = self.buffer.prefix(upTo: newline)
                if let value = try? jsonObject(Data(line)) { self.consume(value) }
                self.buffer.removeSubrange(...newline)
            }
            if self.buffer.count > 65536 { self.buffer.removeAll() }
        }
        do { try task.run() } catch { output.fileHandleForReading.readabilityHandler = nil }
        // Bounded best-effort setup. Monitoring cannot become a prerequisite
        // for connecting on an OS where Apple's log relay is unavailable.
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while task.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            if snapshot()["monitorAvailable"] as? Bool == true { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        lock.lock(); persist(); lock.unlock()
    }

    func bind(runnerPID: Int) {
        lock.lock(); defer { lock.unlock() }
        self.runnerPID = runnerPID
        let events = pending; pending.removeAll()
        for event in events { consume(event) }
        persist()
    }

    func receive(_ event: [String: Any]) { lock.lock(); consume(event); lock.unlock() }

    private func consume(_ event: [String: Any]) {
        if event["kind"] as? String == "monitor_ready" { monitoring = true; persist(); return }
        if event["kind"] as? String == "monitor_unavailable" {
            monitoring = false
            // Losing evidence is not proof that authentication completed.
            if authorization == "required" { authorization = "unverified" }
            persist(); return
        }
        guard runnerPID != nil else {
            pending.append(event); if pending.count > 32 { pending.removeFirst() }; return
        }
        let kind = event["kind"] as? String
        if kind == "client" {
            // Only a single-client event for the exact launched process can
            // associate testmanagerd's following authentication messages.
            managerPID = event["runner"] as? Int == runnerPID ? event["manager"] as? Int : nil
            if managerPID == nil { authorization = "unknown"; persist() }
            return
        }
        consumeAuthorization(event, kind: kind)
    }

    private func consumeAuthorization(_ event: [String: Any], kind: String?) {
        guard let managerPID, event["manager"] as? Int == managerPID, monitoring else { return }
        switch kind {
        case "required": authorization = "required"
        case "authenticated": authorization = "authenticated"
        case "enabled": authorization = "enabled"
        case "disabled": authorization = "unknown"
        default: return
        }
        persist()
    }

    func ready() { lock.lock(); phase = "ready"; authorization = "enabled"; persist(); lock.unlock() }
    func failed(_ message: String) {
        lock.lock(); phase = "failed"; failure = message; persist(); lock.unlock()
    }
    func setPreviewURL(_ url: String) { lock.lock(); previewURL = url; persist(); lock.unlock() }
    func snapshot() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return facts() }

    private func facts() -> [String: Any] {
        let required = authorization == "required" && phase != "failed"
        let completed = authorization == "authenticated" || authorization == "enabled"
        return [
            "phase": phase, "authorization": authorization, "monitorAvailable": monitoring,
            "requiresUserAction": required,
            "reason": required ? "ui_automation_authorization_required" : "runner_\(phase)",
            "evidence": required ? "device_log_exact_runner_pid" : "none",
            "message": required
                ? """
                Please complete Enable UI Automation authentication on the iPhone now. Do not send the\
                 passcode to the agent. Keep this connection attempt running.
                """
                : (failure
                    ?? (authorization == "unverified"
                        ? """
                        An authorization request was observed, but monitoring ended. Check the iPhone;\
                         completion has not been verified.
                        """
                        : phase == "ready"
                            ? "Runner connected."
                            : completed
                                ? """
                        Automation authorization completed; waiting for Runner\
                         readiness. Keep the iPhone unlocked.
                        """
                                : """
                                Waiting for Runner. If Enable UI Automation appears on the iPhone, complete\
                                 authentication there; waiting alone does not confirm a prompt.
                                """)),
            "previewURL": previewURL as Any? ?? NSNull()
        ]
    }
    private func persist() { try? saveJSON(facts(), to: file) }

    @discardableResult func stop() -> Bool {
        lock.lock(); stopped = true; monitoring = false; lock.unlock()
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try? pipe?.fileHandleForReading.close()
        let exited = process?.isRunning != true
        pipe = nil; process = nil
        return exited
    }
    deinit { stop() }
}
