import Foundation

// Accessed only on the host's control queue. Times are monotonic, not wall-clock dates.
struct SessionLifecycle {
    enum Phase { case starting, ready, closing }
    private(set) var phase = Phase.starting
    private(set) var pending = 0
    private(set) var lastActivity: TimeInterval = 0
    let timeout: TimeInterval

    mutating func ready(at now: TimeInterval) {
        phase = .ready
        lastActivity = now
    }

    func isExpired(at now: TimeInterval) -> Bool {
        phase == .ready && pending == 0 && now - lastActivity >= timeout
    }

    mutating func accept(at now: TimeInterval) -> Bool {
        guard phase == .ready, !isExpired(at: now) else { return false }
        pending += 1
        return true
    }

    mutating func finish(effective: Bool, at now: TimeInterval) {
        precondition(pending > 0)
        pending -= 1
        if effective { lastActivity = now }
    }

    mutating func close() { phase = .closing }
}
