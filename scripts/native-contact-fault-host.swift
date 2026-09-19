import Foundation
import Darwin
@testable import AgentSomaCore

// Explicit development-only acceptance harness; never linked into the product CLI.
// It sends no input by itself. Use only with an inspected, controlled Probe observation.
final class ReportRecorder: NativeTransport {
    let base: NativeTransport
    let log: URL
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
        let phase = report.map { $0[3] == 0xc2 ? "contact" : "release" } ?? "other"
        record(["event": "send_attempt", "phase": phase])
        do { try base.send(message, timeout: timeout); record(["event": "send_barrier", "phase": phase]) }
        catch { record(["event": "send_failed", "phase": phase, "error": String(describing: error)]); throw error }
    }
    func cancel() { base.cancel() }
}

@main
struct ContactFaultHost {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 2 && args[1] == "--help" {
            print("ContactFaultHost DEVICE_ID signal-after-contact|close-hid-after-contact NEW_EVIDENCE_DIRECTORY")
            print("Starts only the native host. Inspect a Probe screenshot before issuing a separate tap. No input is replayed.")
            return
        }
        guard args.count == 4, ["signal-after-contact", "close-hid-after-contact"].contains(args[2]) else {
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
                if !injected {
                    injected = true
                    recorder.record(["event": "fault", "mode": args[2]])
                    if args[2] == "signal-after-contact" {
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
}
