import Foundation
import Darwin
@testable import AgentSomaCore

// Explicit development-only acceptance harness; never linked into the product CLI.
// It sends no input by itself. Use only with an inspected, controlled Probe observation.
final class ReportRecorder: NativeTransport {
    let base: NativeTransport
    let log: URL
    private(set) var contactBarriers = 0
    private(set) var moveBarriers = 0
    private var lastQueuedPoint: [Int]?
    private var attempt = 0
    static let movesBeforeFault = 12
    func ready(for mode: String) -> Bool {
        mode.hasSuffix("-after-move") ? moveBarriers >= Self.movesBeforeFault : contactBarriers > 0
    }
    init(_ base: NativeTransport, log: URL) { self.base = base; self.log = log }
    func record(_ event: [String: Any]) {
        var entry = event
        entry["uptime"] = ProcessInfo.processInfo.systemUptime
        guard var data = try? jsonData(entry), let handle = try? FileHandle(forWritingTo: log) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd(); data.append(10); try? handle.write(contentsOf: data)
    }
    func request(_ message: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        try base.request(message, timeout: timeout)
    }
    func send(_ message: [String: Any], timeout: TimeInterval) throws {
        let payload = message["payload"] as? [String: Any]
        let report = (payload?["send"] as? [String: Any])?["_0"] as? Data
        let point = report.flatMap { $0.count == 58 ? [Int($0[4]) | Int($0[5]) << 8, Int($0[6]) | Int($0[7]) << 8] : nil }
        let phase: String
        if let report, let point {
            phase = report[3] == 2 ? "release" : (lastQueuedPoint == nil ? "contact" : (point == lastQueuedPoint ? "hold" : "move"))
        } else { phase = "other" }
        attempt += 1
        var facts: [String: Any] = ["attempt": attempt, "phase": phase, "hidPoint": point as Any? ?? NSNull()]
        record(facts.merging(["event": "send_attempt"]) { _, new in new })
        do {
            try base.send(message, timeout: timeout)
            if phase == "contact" { contactBarriers += 1 }
            if phase == "move" { moveBarriers += 1 }
            if phase != "other" { lastQueuedPoint = phase == "release" ? nil : point }
            facts["moveBarriers"] = moveBarriers
            record(facts.merging(["event": "send_barrier"]) { _, new in new })
        } catch {
            record(facts.merging(["event": "send_failed", "error": String(describing: error),
                                 "possiblySent": (error as? TransportError)?.possiblySent as Any? ?? NSNull()]) { _, new in new })
            throw error
        }
    }
    func cancel() { base.cancel() }
}

@main
struct ContactFaultHost {
    static let modes = ["signal-after-contact", "close-hid-after-contact", "signal-after-move", "close-hid-after-move"]
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 2 && args[1] == "--help" {
            print("ContactFaultHost DEVICE_ID \(modes.joined(separator: "|")) NEW_EVIDENCE_DIRECTORY")
            print("Starts only the native host. Inspect and archive a Probe screenshot before a separate tap/swipe. Move modes wait for 12 changed-position send barriers, not a timer. No input is replayed.")
            print("ContactFaultHost --self-test checks fault arming with a fake transport; no device access.")
            return
        }
        if args.count == 2 && args[1] == "--self-test" { try selfTest(); return }
        guard args.count == 4, modes.contains(args[2]) else {
            throw SomaError("usage", "Use --help; requires device, fault mode and new evidence directory")
        }
        umask(0o077)
        let evidence = URL(fileURLWithPath: args[3]).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: evidence.path) else {
            throw SomaError("existing_evidence", "Use a new evidence directory")
        }
        try SessionPaths.secureDirectory(evidence)
        let session = "s" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let paths = try SessionPaths(session: session)
        try SessionPaths.secureDirectory(paths.directory)
        let directory = paths.directory
        let config = HostConfiguration(session: session, device: args[1], xctestrun: "",
                                       idleTimeoutSeconds: 300, backend: "apple-native")
        try JSONEncoder().encode(config).write(to: paths.config, options: .atomic)
        let identity: [String: Any] = ["session": session, "directory": directory.path,
            "hostPid": getpid(), "mode": args[2], "inputSentByHarness": false]
        try saveJSON(identity, to: evidence.appendingPathComponent("session.json"))
        print(String(decoding: try jsonData(identity), as: UTF8.self)); fflush(stdout)
        defer {
            for name in ["exit.json", "native-events.jsonl", "fault-events.jsonl", "startup-error.json"] {
                let source = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: source.path) {
                    try? FileManager.default.copyItem(at: source, to: evidence.appendingPathComponent(name))
                }
            }
        }
        let log = directory.appendingPathComponent("fault-events.jsonl")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let backend = AppleDeviceBackend(config: config, paths: paths, makeHID: { transport, cancellation in
            let recorder = ReportRecorder(transport, log: log)
            var injected = false
            return NativeHIDAdapter(transport: recorder, cancellation: cancellation, wait: { duration in
                if !injected && recorder.ready(for: args[2]) {
                    injected = true
                    recorder.record(["event": "fault", "mode": args[2], "moveBarriers": recorder.moveBarriers])
                    if args[2].hasPrefix("signal-") {
                        kill(getpid(), SIGTERM)
                        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
                        while !cancellation.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
                            Thread.sleep(forTimeInterval: 0.001)
                        }
                        recorder.record(["event": "signal_cancellation_observed", "cancelled": cancellation.isCancelled])
                    } else {
                        transport.cancel() // Only this client's HID channel; media and pairing remain owned.
                        recorder.record(["event": "hid_connection_closed"])
                    }
                }
                Thread.sleep(forTimeInterval: duration)
            })
        })
        try SessionHost(config: config, paths: paths, backend: backend).run()
    }

    static func selfTest() throws {
        final class FakeTransport: NativeTransport {
            var fail = false
            func request(_ message: [String: Any], timeout: TimeInterval) throws -> [String: Any] { [:] }
            func send(_ message: [String: Any], timeout: TimeInterval) throws {
                if fail { throw TransportError(description: "test failed send", possiblySent: true) }
            }
            func cancel() {}
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-fault-self-test-\(UUID().uuidString)")
        try SessionPaths.secureDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("events.jsonl")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let fake = FakeTransport(), recorder = ReportRecorder(FakeTransport(), log: log)
        let failed = ReportRecorder(fake, log: log)
        func require(_ value: Bool) throws { if !value { throw SomaError("self_test_failed", "Fault armed without the required successful MOVE barriers") } }
        func send(_ recorder: ReportRecorder, x: UInt16) throws {
            try recorder.send(["payload": ["send": ["_0": NativeTouchReport.make(contact: true, x: x, y: 100, timestamp: 1)]]], timeout: 1)
        }
        try require(modes.allSatisfy { !recorder.ready(for: $0) })
        try send(recorder, x: 100)
        for _ in 0..<20 { try send(recorder, x: 100) }
        try require(recorder.contactBarriers == 1 && recorder.moveBarriers == 0)
        try require(recorder.ready(for: "signal-after-contact") && !recorder.ready(for: "signal-after-move"))
        for index in 1...ReportRecorder.movesBeforeFault {
            try send(recorder, x: UInt16(100 + index))
            try require(recorder.ready(for: "signal-after-move") == (index == ReportRecorder.movesBeforeFault))
        }
        try require(recorder.ready(for: "close-hid-after-move"))
        try send(failed, x: 100)
        fake.fail = true
        for index in 1...20 { do { try send(failed, x: UInt16(100 + index)); throw SomaError("self_test_failed", "Expected transport failure") } catch is TransportError {} }
        try require(failed.moveBarriers == 0 && !failed.ready(for: "close-hid-after-move"))
        print("PASS: first contact, stationary updates and failed sends cannot arm MOVE faults; 12 changed-position send barriers can. Host fake transport only.")
    }
}
