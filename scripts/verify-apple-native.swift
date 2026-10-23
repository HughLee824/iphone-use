#!/usr/bin/env swift
// Device acceptance, not a host unit test. Uses only the built CLI and Apple system tools.
// No tap, app launch, screenshot, Runner, settings changes or automatic reconnect on failure.
import Foundation
import Darwin

typealias Object = [String: Any]
struct CheckFailure: Error, CustomStringConvertible { let description: String }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw CheckFailure(description: message) }
}
func object(_ data: Data) throws -> Object {
    guard let value = try JSONSerialization.jsonObject(with: data) as? Object else {
        throw CheckFailure(description: "Expected JSON object")
    }
    return value
}
func save(_ value: Object, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(
        to: url, options: .atomic)
}
final class Interrupt {
    private let lock = NSLock()
    private var stopped = false
    private var sources: [DispatchSourceSignal] = []
    init() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                self?.lock.lock(); self?.stopped = true; self?.lock.unlock()
            }
            source.resume(); sources.append(source)
        }
    }
    func check() throws {
        lock.lock(); let value = stopped; lock.unlock()
        try require(!value, "Interrupted; cleanup requested for the owned session")
    }
    func pause(_ duration: Double) throws {
        let until = ProcessInfo.processInfo.systemUptime + duration
        while ProcessInfo.processInfo.systemUptime < until {
            try check()
            Thread.sleep(forTimeInterval: min(0.1, max(0, until - ProcessInfo.processInfo.systemUptime)))
        }
    }
}

var options: [String: String] = [:]
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") {
    print(
        """
        swift scripts/verify-apple-native.swift --output NEW_PRIVATE_DIRECTORY [--cli\
         .build/release/iphone-use] [--device ID] [--duration 300] [--cycles 3] [--interval 15]
        """
    )
    print(
        """
        First cycle holds media for duration seconds; later cycles verify new sessions for one interval.\
         Auto-selects exactly one wired iPhone. Sends no input. Exit 0 requires protocol, packet flow and\
         owned cleanup checks, not just command success.
        """
    )
    exit(0)
}
func main() throws {
    try require(arguments.count % 2 == 0, "Options require values; use --help")
    for index in stride(from: 0, to: arguments.count, by: 2) {
        let key = arguments[index]
        try require(
            ["--output", "--cli", "--device", "--duration", "--cycles", "--interval"].contains(key)
                && options[key] == nil, "Unknown/duplicate option: \(key)")
        options[key] = arguments[index + 1]
    }
    guard let outputPath = options["--output"],
        let duration = Double(options["--duration"] ?? "300"), duration.isFinite,
        (10...3600).contains(duration),
        let interval = Double(options["--interval"] ?? "15"), interval.isFinite, (1...60).contains(interval),
        interval <= duration,
        let cycles = Int(options["--cycles"] ?? "3"), (1...20).contains(cycles)
    else {
        throw CheckFailure(
            description:
                "Require --output and valid duration 10...3600, interval 1...60 <= duration, cycles 1...20")
    }
    umask(0o077)
    let files = FileManager.default
    let output = URL(fileURLWithPath: outputPath).standardizedFileURL
    try require(!files.fileExists(atPath: output.path), "Output must be a new directory")
    try files.createDirectory(
        at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let cli = URL(fileURLWithPath: options["--cli"] ?? ".build/release/iphone-use").standardizedFileURL.path
    try AcceptanceRun(output: output, cli: cli, duration: duration, interval: interval, cycles: cycles).run()
}

final class AcceptanceRun {
    let output: URL
    let cli: String
    let duration: Double
    let interval: Double
    let cycles: Int
    let files = FileManager.default
    init(output: URL, cli: String, duration: Double, interval: Double, cycles: Int) {
        self.output = output; self.cli = cli; self.duration = duration
        self.interval = interval; self.cycles = cycles
    }
    let interrupt = Interrupt()
    var commandNumber = 0
    func command(_ executable: String, _ args: [String], timeout: Double = 90) throws -> (Int32, Data) {
        commandNumber += 1
        let stem = String(format: "command-%03d", commandNumber)
        let stdout = output.appendingPathComponent(stem + ".stdout")
        let stderr = output.appendingPathComponent(stem + ".stderr")
        files.createFile(atPath: stdout.path, contents: nil)
        files.createFile(atPath: stderr.path, contents: nil)
        let out = try FileHandle(forWritingTo: stdout), err = try FileHandle(forWritingTo: stderr)
        defer { try? out.close(); try? err.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
        process.standardInput = FileHandle.nullDevice; process.standardOutput = out
        process.standardError = err
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let end = ProcessInfo.processInfo.systemUptime + 2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < end {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw CheckFailure(description: "Command timed out; no retry: \(executable) \(args). See \(stem)")
        }
        process.waitUntilExit()
        return (process.terminationStatus, try Data(contentsOf: stdout))
    }
    func call(_ args: [String], timeout: Double = 90) throws -> Object {
        let (_, data) = try command(cli, args, timeout: timeout)
        // The response contract is checked by the caller; exit status alone never passes acceptance.
        return try object(data)
    }
    var active: Object?
    var completed: [Object] = []
    func cleanup(_ info: Object, cycle: Int) throws {
        let session = validatedValue(info["session"], as: String.self)
        let response = try call(["--session", session, "disconnect"])
        try save(response, to: output.appendingPathComponent("cycle-\(cycle)-disconnect.json"))
        let result = response["result"] as? Object ?? [:], facts = result["cleanup"] as? Object ?? [:]
        let directory = URL(fileURLWithPath: validatedValue(info["directory"], as: String.self))
        for name in ["config.json", "exit.json", "host.log", "native-control.json", "native-events.jsonl"] {
            let source = directory.appendingPathComponent(name)
            if files.fileExists(atPath: source.path) {
                try files.copyItem(at: source, to: output.appendingPathComponent("cycle-\(cycle)-\(name)"))
            }
        }
        for key in [
            "mediaStopAcknowledged", "tunnelReleaseAcknowledged", "observationCacheRemoved",
            "connectionsClosed",
            "receiverClosed", "shutdownAcknowledged"
        ] {
            try require(facts[key] as? Bool == true, "Cleanup not confirmed: \(key), cycle \(cycle)")
        }
        try require(
            response["ok"] as? Bool == true && facts["releaseUncertain"] as? Bool == false,
            "Uncertain shutdown")
        let pid = (validatedValue(info["hostPid"], as: NSNumber.self)).int32Value
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while kill(pid, 0) == 0 && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        try require(kill(pid, 0) == -1 && errno == ESRCH, "Owned host did not exit")
        try require(
            !files.fileExists(atPath: directory.appendingPathComponent("observations").path),
            "Observation cache remains")
    }
    var cycle = 0
    func run() throws {
        do {
            let device = try selectedDevice()
            for current in 1...cycles {
                cycle = current; try interrupt.check()
                // Status intentionally does not refresh the product's idle timer.
                let idleTimeout = "\(Int(duration) + 120)s"
                let connected = try call(
                    [
                        "connect", "--backend", "apple-native", "--device", device, "--idle-timeout",
                        idleTimeout
                    ],
                    timeout: 180)
                try save(connected, to: output.appendingPathComponent("cycle-\(cycle)-connect.json"))
                guard let session = connected["session"] as? String, connected["directory"] is String,
                    connected["hostPid"] is NSNumber
                else {
                    throw CheckFailure(
                        description:
                            "Connect supplied no owned session; inspect command logs; no automatic retry")
                }
                active = connected
                try require(connected["ok"] as? Bool == true, "Connect failed")
                let sample = try sampleSession(connected, session: session)
                active = nil // Never retry uncertain cleanup automatically.
                try cleanup(connected, cycle: cycle)
                completed.append([
                    "cycle": cycle, "samples": sample.count, "rtpPackets": sample.packets,
                    "rtcpReports": sample.reports,
                    "cleanupVerified": true
                ])
            }
            try saveSuccess()
        } catch {
            var failure: Object = [
                "passed": false, "error": String(describing: error), "completed": completed
            ]
            if let info = active {
                active = nil
                do { try cleanup(info, cycle: cycle); failure["cleanupVerified"] = true } catch {
                    failure["cleanupError"] = String(describing: error)
                }
            }
            try? save(failure, to: output.appendingPathComponent("result.json"))
            throw error
        }
    }
    struct Sample {
        let count: Int
        let packets: Int
        let reports: Int
    }
    func sampleSession(_ connected: Object, session: String) throws -> Sample {
        let started = ProcessInfo.processInfo.systemUptime
        let hold = cycle == 1 ? duration : interval
        var samples: [Object] = [], firstPackets: Int?, lastPackets = 0, lastReports = 0
        repeat {
            try interrupt.check()
            let response = try call(["--session", session, "status"])
            let result = response["result"] as? Object ?? [:], media = result["media"] as? Object ?? [:]
            try require(
                response["ok"] as? Bool == true && result["controlAvailable"] as? Bool == true
                    && result["runnerStarted"] as? Bool == false
                    && result["serviceTransport"] as? String == "apple-coredevice-service-socket",
                "Native control unavailable")
            guard let packets = media["rtpPackets"] as? Int, let reports = media["rtcpReports"] as? Int else {
                throw CheckFailure(description: "Missing media counters")
            }
            try require(
                media["healthy"] as? Bool == true && packets >= lastPackets && reports >= lastReports
                    && reports > 0, "Media stalled/failed or counters regressed")
            firstPackets = firstPackets ?? packets; lastPackets = packets; lastReports = reports
            let pid = (validatedValue(connected["hostPid"], as: NSNumber.self)).intValue
            let (psStatus, rss) = try command("/bin/ps", ["-p", String(pid), "-o", "rss="])
            let (fdStatus, fds) = try command(
                "/usr/sbin/lsof", ["-a", "-p", String(pid), "-F", "f"], timeout: 10)
            let descriptorCount = decodeOutput(fds).split(separator: "\n").filter {
                $0.hasPrefix("f") && Int($0.dropFirst()) != nil
            }.count
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            samples.append([
                "elapsed": elapsed, "status": response,
                "rssKB": psStatus == 0
                    ? Int(decodeOutput(rss).trimmingCharacters(in: .whitespacesAndNewlines))
                        as Any? ?? NSNull() : NSNull(),
                "openDescriptors": fdStatus == 0 ? descriptorCount as Any : NSNull()
            ])
            try save(["samples": samples], to: output.appendingPathComponent("cycle-\(cycle)-samples.json"))
            print("cycle \(cycle)/\(cycles) elapsed=\(Int(elapsed))s RTP=\(packets) RTCP=\(reports)")
            fflush(stdout)
            if elapsed >= hold { break }
            try interrupt.pause(min(interval, hold - elapsed))
        } while true
        try require(lastPackets > firstPackets!, "No packet progress during sample interval")
        return Sample(count: samples.count, packets: lastPackets, reports: lastReports)
    }

    private func saveSuccess() throws {
            try save(
                [
                    "passed": true, "cycles": completed,
                    "scope":
                        """
                        Media/lifecycle only; no touch or image acceptance; RSS/FD\
                         samples do not prove absence of leaks
                        """
                ], to: output.appendingPathComponent("result.json"))
    }

    private func selectedDevice() throws -> String {
        let inventory = try call(["devices"])
        try save(inventory, to: output.appendingPathComponent("devices.json"))
        let devices = (inventory["result"] as? Object)?["devices"] as? [Object] ?? []
        let candidates = devices.filter {
            if let requested = options["--device"] { return $0["id"] as? String == requested }
            return $0["deviceType"] as? String == "iPhone"
                && ($0["connection"] as? Object)?["transport"] as? String == "wired"
        }
        try require(candidates.count == 1, "Select exactly one discovered device with --device")
        return validatedValue(candidates[0]["id"], as: String.self)
    }

}

do { try main() } catch { fputs("Acceptance failed: \(error)\n", stderr); exit(1) }

func validatedValue<Value>(_ value: Any?, as type: Value.Type) -> Value {
    guard let value = value as? Value else { preconditionFailure("Invalid validated value for \(type)") }
    return value
}

func decodeOutput(_ data: Data) -> String {
    if let text = String(data: data, encoding: .utf8) { return text }
    var decoder = Unicode.UTF8()
    var bytes = data.makeIterator()
    var text = String.UnicodeScalarView()
    while true {
        switch decoder.decode(&bytes) {
        case .scalarValue(let scalar): text.append(scalar)
        case .error: text.append("\u{FFFD}")
        case .emptyInput: return String(text)
        }
    }

}
