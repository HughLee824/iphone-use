import Foundation
import Darwin

// Observe kernel exit, including an unreaped child; a disconnected socket or
// released lock alone does not prove that the target process has exited.
final class PreviewProcessExit {
    private let descriptor: Int32
    private let alreadyExited: Bool

    init(pid: Int32) throws {
        guard pid > 1 else { throw IPhoneUseError("invalid_preview_process", "Invalid service process ID") }
        descriptor = kqueue()
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var event = kevent64_s()
        event.ident = UInt64(pid); event.filter = Int16(EVFILT_PROC)
        event.flags = UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT); event.fflags = UInt32(NOTE_EXIT)
        if kevent64(descriptor, &event, 1, nil, 0, 0, nil) == 0 {
            alreadyExited = false
        } else {
            let code = errno
            guard code == ESRCH else {
                Darwin.close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            alreadyExited = true
        }
    }

    deinit { Darwin.close(descriptor) }

    func wait(timeout: TimeInterval) -> Bool {
        if alreadyExited { return true }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            var interval = timespec(tv_sec: Int(remaining),
                                    tv_nsec: Int(remaining.truncatingRemainder(dividingBy: 1) * 1e9))
            var event = kevent64_s()
            let count = kevent64(descriptor, nil, 0, &event, 1, 0, &interval)
            if count > 0 { return event.flags & UInt16(EV_ERROR) == 0 && event.fflags & UInt32(NOTE_EXIT) != 0 }
            if count == 0 || errno != EINTR { return false }
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }
}

enum PreviewServiceProcess {
    // The Process must belong to this startup attempt. Never terminate a daemon
    // found through IPC or an ownership lock, and never replay its registration.
    static func waitForStartup(
        _ process: Process, timeout: TimeInterval = 6, terminationGrace: TimeInterval = 2,
        ready: () -> Bool
    ) throws -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            if ready() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard process.isRunning else { return false }
        process.terminate()
        let cleanupDeadline = ProcessInfo.processInfo.systemUptime + terminationGrace
        while process.isRunning, ProcessInfo.processInfo.systemUptime < cleanupDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !process.isRunning else {
            throw IPhoneUseError("preview_service_cleanup_pending",
                                 "Startup timed out; termination requested for the new child, but exit is unconfirmed")
        }
        return false
    }
}
