import Foundation

// One capture only. Lock/display queries run concurrently; join them before
// reading these records. Never retain command arguments, PNG bytes or UI text.
final class NativeCaptureDiagnostics {
    private let lock = NSLock()
    private var records: [[String: Any]] = []

    func read(
        _ arguments: [String], phase: String,
        operation: () throws -> [String: Any]
    ) throws -> [String: Any] {
        let started = ProcessInfo.processInfo.systemUptime
        var record: [String: Any] = [
            "phase": phase,
            "command": arguments.prefix { !$0.hasPrefix("--") }.joined(separator: " ")
        ]
        defer {
            record["elapsedMs"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
            lock.lock(); records.append(record); lock.unlock()
        }
        do {
            let value = try operation()
            record["ok"] = true
            return value
        } catch {
            record["ok"] = false
            record["errorCode"] = (error as? IPhoneUseError)?.code ?? "capture_failed"
            record["process"] = (error as? IPhoneUseError)?.diagnostics["process"]
            throw error
        }
    }

    var commands: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return records
    }
}
