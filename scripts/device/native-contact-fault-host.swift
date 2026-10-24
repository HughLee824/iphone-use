import Foundation
import Darwin
import AppleNativeBridge
@testable import IPhoneUseCore

// Explicit development-only acceptance harness; never linked into the product CLI.
// It sends no input by itself. Use only with an inspected, controlled Probe observation.
final class ReportRecorder: NativeTransport {
    let base: NativeTransport
    let log: URL
    private(set) var contactBarriers = 0
    private(set) var moveBarriers = 0
    private(set) var keyboardBarriers = 0
    private(set) var selectAllReleases = 0
    private(set) var pasteBarriers = 0
    private var lastKeys: [Int]?
    var diagnostics: [String: Any] { base.diagnostics }
    private var lastQueuedPoint: [Int]?
    private var attempt = 0
    static let movesBeforeFault = 12
    func ready(for mode: String) -> Bool {
        if mode == "signal-after-select-all" { return selectAllReleases > 0 }
        if mode == "close-hid-after-paste" { return pasteBarriers > 0 }
        if mode == "signal-before-key" { return false } // Only the text-entry uptime checkpoint can arm this.
        return mode.hasSuffix("-after-move") ? moveBarriers >= Self.movesBeforeFault : contactBarriers > 0
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
    func canInterruptBeforeKey(_ hid: NativeHIDAdapter?) -> Bool {
        hid?.keyboardStatus["prepared"] as? Bool == true && keyboardBarriers == 0
    }
    func send(_ message: [String: Any], timeout: TimeInterval) throws {
        let payload = message["payload"] as? [String: Any]
        let report = (payload?["send"] as? [String: Any])?["_0"] as? Data
        let point = report.flatMap {
            $0.count == 58 ? [Int($0[4]) | Int($0[5]) << 8, Int($0[6]) | Int($0[7]) << 8] : nil
        }
        let keys: [Int]? = report.flatMap { data in
            guard data.count == 39, data[0] == 1 else { return nil }
            return (0..<240).filter { data[1 + $0 / 8] & (1 << ($0 % 8)) != 0 }
        }
        let phase: String
        if let report, let point {
            phase =
                report[3] == 2
                ? "release"
                : (lastQueuedPoint == nil ? "contact" : (point == lastQueuedPoint ? "hold" : "move"))
        } else if let keys {
            phase = keys.isEmpty ? "key_release" : "keys"
        } else {
            phase = "other"
        }
        attempt += 1
        var facts: [String: Any] = ["attempt": attempt, "phase": phase, "hidPoint": point as Any? ?? NSNull()]
        if let keys { facts["keys"] = keys }
        record(facts.merging(["event": "send_attempt"]) { _, new in new })
        do {
            try base.send(message, timeout: timeout)
            recordBarrier(phase: phase, point: point, keys: keys)
            facts["moveBarriers"] = moveBarriers
            record(facts.merging(["event": "send_barrier"]) { _, new in new })
        } catch {
            record(
                facts.merging([
                    "event": "send_failed", "error": String(describing: error),
                    "possiblySent": (error as? TransportError)?.possiblySent as Any? ?? NSNull()
                ]) { _, new in new })
            throw error
        }
    }
    private func recordBarrier(phase: String, point: [Int]?, keys: [Int]?) {
        if phase == "contact" { contactBarriers += 1 }
        if phase == "move" { moveBarriers += 1 }
        if let point { lastQueuedPoint = phase == "release" ? nil : point }
        if let keys {
            keyboardBarriers += 1
            if keys.isEmpty && lastKeys == [0x04, 0xe3] { selectAllReleases += 1 }
            if keys == [0x19, 0xe3] { pasteBarriers += 1 }
            lastKeys = keys
        }
    }
    func cancel() { base.cancel() }
}

@main
struct ContactFaultHost {
    static let modes = [
        "signal-after-contact", "close-hid-after-contact", "signal-after-move", "close-hid-after-move",
        "signal-before-key", "signal-after-select-all", "close-hid-after-paste"
    ]
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 2 && args[1] == "--help" {
            printHelp()
            return
        }
        if args.count == 2 && args[1] == "--self-test" { try selfTest(); return }
        guard args.count == 4, modes.contains(args[2]) else {
            throw IPhoneUseError(
                "usage", "Use --help; requires device, fault mode and new evidence directory")
        }
        umask(0o077)
        let evidence = URL(fileURLWithPath: args[3]).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: evidence.path) else {
            throw IPhoneUseError("existing_evidence", "Use a new evidence directory")
        }
        try SessionPaths.secureDirectory(evidence)
        let session = "s" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let paths = try SessionPaths(session: session)
        try SessionPaths.secureDirectory(paths.directory)
        let directory = paths.directory
        let config = HostConfiguration(
            session: session, device: args[1], xctestrun: "",
            idleTimeoutSeconds: 300, backend: "apple-native")
        try JSONEncoder().encode(config).write(to: paths.config, options: .atomic)
        let identity: [String: Any] = [
            "session": session, "directory": directory.path,
            "hostPid": getpid(), "mode": args[2], "inputSentByHarness": false
        ]
        try saveJSON(identity, to: evidence.appendingPathComponent("session.json"))
        print(String(data: try jsonData(identity), encoding: .utf8)!); fflush(stdout)
        defer {
            for name in ["exit.json", "native-events.jsonl", "fault-events.jsonl", "startup-error.json"] {
                let source = directory.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: source.path) {
                    try? FileManager.default.copyItem(at: source, to: evidence.appendingPathComponent(name))
                }
            }
        }
        let log = directory.appendingPathComponent("fault-events.jsonl")
        FileManager.default.createFile(
            atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let backend = AppleDeviceBackend(
            config: config, paths: paths,
            makeHID: { transport, cancellation in
                makeHID(transport: transport, cancellation: cancellation, log: log, mode: args[2])
            })
        try SessionHost(config: config, paths: paths, backend: backend).run()
    }

    static func require(_ value: Bool, line: UInt = #line) throws {
        if !value {
            throw IPhoneUseError(
                "self_test_failed", "Fault checkpoint did not match the required report barriers at line \(line)")
        }
    }
    static func send(_ recorder: ReportRecorder, x column: UInt16) throws {
        try recorder.send(
            [
                "payload": [
                    "send": ["_0": NativeTouchReport.make(contact: true, x: column, y: 100, timestamp: 1)]
                ]
            ],
            timeout: 1)
    }
    static func makeHID(
        transport: NativeTransport, cancellation: NativeCancellation, log: URL, mode: String
    ) -> NativeHIDAdapter {
        let recorder = ReportRecorder(transport, log: log)
        var injected = false
        func inject() {
            if !injected {
                injected = true
                recorder.record([
                    "event": "fault", "mode": mode, "moveBarriers": recorder.moveBarriers,
                    "keyboardBarriers": recorder.keyboardBarriers,
                    "selectAllReleases": recorder.selectAllReleases,
                    "pasteBarriers": recorder.pasteBarriers
                ])
                if mode.hasPrefix("signal-") {
                    kill(getpid(), SIGTERM)
                    let deadline = ProcessInfo.processInfo.systemUptime + 0.5
                    while !cancellation.isCancelled && ProcessInfo.processInfo.systemUptime < deadline {
                        Thread.sleep(forTimeInterval: 0.001)
                    }
                    recorder.record([
                        "event": "signal_cancellation_observed", "cancelled": cancellation.isCancelled
                    ])
                    // A delayed signal must not allow the test's input to proceed.
                    // This fallback makes OS-signal acceptance fail, but safely cancels input.
                    if !cancellation.isCancelled {
                        cancellation.cancel(); recorder.record(["event": "signal_timeout_fallback"])
                    }
                } else {
                    transport.cancel() // Only this client's HID channel; media and pairing remain owned.
                    recorder.record(["event": "hid_connection_closed"])
                }
            }
        }
        weak var preparedAdapter: NativeHIDAdapter?
        let adapter = NativeHIDAdapter(
            transport: recorder, cancellation: cancellation,
            wait: { duration in
                if recorder.ready(for: mode) { inject() }
                Thread.sleep(forTimeInterval: duration)
            },
            uptime: {
                // Inventory discovery alone must not arm a fault during startup.
                // The prepared keyboard reaches this clock before its first report.
                if mode == "signal-before-key", recorder.canInterruptBeforeKey(preparedAdapter) {
                    inject()
                }
                return ProcessInfo.processInfo.systemUptime
            })
        preparedAdapter = adapter
        return adapter
    }
    static func checkInterruptedPaste(log: URL) throws {
        for mode in ["signal-before-key", "signal-after-select-all", "close-hid-after-paste"] {
            let transport = FakeTransport(), cancellation = NativeCancellation()
            let reports = ReportRecorder(transport, log: log)
            var now: TimeInterval = 0, injected = false
            weak var preparedAdapter: NativeHIDAdapter?
            let hid = NativeHIDAdapter(
                transport: reports, cancellation: cancellation,
                wait: { duration in
                    if !injected && reports.ready(for: mode) {
                        injected = true
                        if mode.hasPrefix("signal-") { cancellation.cancel() } else { transport.cancel() }
                    }
                    now += duration
                },
                uptime: {
                    if mode == "signal-before-key", reports.canInterruptBeforeKey(preparedAdapter) {
                        injected = true; cancellation.cancel()
                    }
                    return now
                })
            preparedAdapter = hid
            try hid.prepare()
            try require(!reports.canInterruptBeforeKey(hid) && !injected)
            try hid.prepareKeyboard()
            try require(reports.canInterruptBeforeKey(hid) && !injected && reports.keyboardBarriers == 0)
            do {
                _ = try hid.paste(mode: "replace")
                throw IPhoneUseError("self_test_failed", "Interrupted paste unexpectedly completed")
            } catch let failure as ActionFailure {
                try require(mode != "signal-before-key" && failure.possiblyExecuted)
            } catch let error as IPhoneUseError {
                try require(mode == "signal-before-key" && error.code == "native_cancelled")
            }
            try require(injected)
            try require(transport.unexpectedRequests == 0)
            try require(transport.keyboardDestinations.allSatisfy { $0 == FakeTransport.keyboardID })
            let expectedReports = mode == "signal-before-key" ? 0 : (mode == "signal-after-select-all" ? 3 : 7)
            try require(transport.keyboardDestinations.count == expectedReports)
            if mode == "signal-before-key" { try require(reports.keyboardBarriers == 0) }
            if mode == "signal-after-select-all" {
                try require(
                    reports.keyboardBarriers == 3 && reports.selectAllReleases == 1
                        && reports.pasteBarriers == 0
                        && !hid.releaseUncertain)
            }
            if mode == "close-hid-after-paste" {
                try require(
                    reports.keyboardBarriers == 5 && reports.pasteBarriers == 1 && hid.releaseUncertain)
            }
        }
    }
    static func printHelp() {
        print("""
            ContactFaultHost DEVICE_ID \(modes.joined(separator: "|")) NEW_EVIDENCE_DIRECTORY
            Starts only the native host. Inspect and archive a Probe screenshot before a separate\
             tap/swipe/type. Move modes wait for 12 changed-position send barriers, not a timer. No input\
             is replayed.
            ContactFaultHost --self-test checks fault arming with a fake transport; no device access.
            Text modes: use type with --method paste on Probe. signal-before-key interrupts at the\
             text-entry clock read after clipboard preflights but before any keyboard report; do not use\
             swipe with this mode. signal-after-select-all requires replace; close-hid-after-paste closes\
             only this client's HID channel after the Command-V send barrier, before release. Neither\
             confirms device delivery.
            """)
    }
    static func checkKeyboardBarriers(log: URL, failed: ReportRecorder) throws {
        let keyboard = ReportRecorder(FakeTransport(), log: log)
        func key(_ keys: [UInt8]) throws {
            try keyboard.send(
                ["payload": ["send": ["_0": NativeKeyboard.report(keys, timestamp: 1)]]], timeout: 1)
        }
        try key([0xe3]); try key([0xe3, 0x04])
        try require(!keyboard.ready(for: "signal-after-select-all"))
        try key([])
        try require(
            keyboard.ready(for: "signal-after-select-all") && !keyboard.ready(for: "close-hid-after-paste"))
        try key([0xe3]); try key([0xe3, 0x19])
        try require(keyboard.ready(for: "close-hid-after-paste"))
        for keys: [UInt8] in [[0xe3, 0x04], [], [0xe3, 0x19]] {
            do {
                try failed.send(
                    ["payload": ["send": ["_0": NativeKeyboard.report(keys, timestamp: 1)]]], timeout: 1)
            } catch is TransportError {}
        }
        try require(
            !failed.ready(for: "signal-after-select-all") && !failed.ready(for: "close-hid-after-paste"))
    }
    static func selfTest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "native-fault-self-test-\(UUID().uuidString)")
        try SessionPaths.secureDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("events.jsonl")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        try checkKeyboardDiscovery(log: log)
        let fake = FakeTransport(), recorder = ReportRecorder(FakeTransport(), log: log)
        let failed = ReportRecorder(fake, log: log)
        try require(modes.allSatisfy { !recorder.ready(for: $0) })
        try send(recorder, x: 100)
        for _ in 0..<20 { try send(recorder, x: 100) }
        try require(recorder.contactBarriers == 1 && recorder.moveBarriers == 0)
        try require(recorder.ready(for: "signal-after-contact") && !recorder.ready(for: "signal-after-move"))
        for index in 1...ReportRecorder.movesBeforeFault {
            try send(recorder, x: UInt16(100 + index))
            try require(
                recorder.ready(for: "signal-after-move") == (index == ReportRecorder.movesBeforeFault))
        }
        try require(recorder.ready(for: "close-hid-after-move"))
        try send(failed, x: 100)
        fake.fail = true
        for index in 1...20 {
            do {
                try send(failed, x: UInt16(100 + index))
                throw IPhoneUseError("self_test_failed", "Expected transport failure")
            } catch is TransportError {}
        }
        try require(failed.moveBarriers == 0 && !failed.ready(for: "close-hid-after-move"))
        try checkKeyboardBarriers(log: log, failed: failed)
        try checkInterruptedPaste(log: log)
        print("PASS: touch/move barriers, built-in keyboard discovery, and all three interrupted-paste checkpoints.")
        print("Fake transport only; no device or OS-signal validation. Failed sends do not arm faults; no replay.")
    }
}

extension ContactFaultHost {
    static func checkKeyboardDiscovery(log: URL) throws {
        for inventory in [[], [FakeTransport.keyboard, FakeTransport.keyboard]] {
            let transport = FakeTransport(), cancellation = NativeCancellation()
            let recorder = ReportRecorder(transport, log: log)
            transport.services = [transport.services[0]] + inventory
            let hid = NativeHIDAdapter(transport: recorder, cancellation: cancellation, wait: { _ in })
            try hid.prepare()
            do {
                try hid.prepareKeyboard()
                throw IPhoneUseError("self_test_failed", "Missing or ambiguous keyboard unexpectedly prepared")
            } catch let failure as ActionFailure {
                try require(failure.code == "native_keyboard_unavailable" && !failure.possiblyExecuted)
            }
            try require(!recorder.canInterruptBeforeKey(hid))
            try require(recorder.keyboardBarriers == 0 && transport.keyboardDestinations.isEmpty)
            try require(transport.unexpectedRequests == 0)
        }
    }
}

final class FakeTransport: NativeTransport {
    var fail = false
    static let keyboardID: UInt64 = 761
    static let keyboard: [String: Any] = [
        "_ServiceID": keyboardID, "PrimaryUsagePage": 0, "PrimaryUsage": 0,
        "DeviceTypeHint": "Keyboard", "Product": "CoreDevice keyboard",
        "_CoreDevice_codablePropertyStorage": [
            "Transport": ["string": "CoreDevice"],
            "_CoreDevice_originalUsages": ["array": [
                ["dictionary": ["DeviceUsagePage": ["int": 1], "DeviceUsage": ["int": 6]]]
            ]]
        ]
    ]
    var services: [[String: Any]] = [
        ["_ServiceID": 987, "PrimaryUsagePage": 13, "PrimaryUsage": 4, "UniversalControlBuiltIn": true],
        keyboard
    ]
    private(set) var unexpectedRequests = 0
    private(set) var keyboardDestinations: [UInt64] = []
    func request(_ message: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        let payload = message["payload"] as? [String: Any] ?? [:]
        if payload["connectedServices"] != nil { return ["connectedServices": services] }
        unexpectedRequests += 1
        throw IPhoneUseError("self_test_request", "Only built-in service discovery is expected")
    }
    func send(_ message: [String: Any], timeout: TimeInterval) throws {
        guard let payload = message["payload"] as? [String: Any], let send = payload["send"] as? [String: Any] else {
            unexpectedRequests += 1
            throw IPhoneUseError("self_test_request", "Only HID reports are expected; services must not be removed")
        }
        if let report = send["_0"] as? Data, report.count == 39,
            let destination = send["_1"] as? ASNativeUnsigned {
            keyboardDestinations.append(destination.value)
        }
        if fail { throw TransportError(description: "test failed send", possiblySent: true) }
    }
    func cancel() { fail = true }
}
