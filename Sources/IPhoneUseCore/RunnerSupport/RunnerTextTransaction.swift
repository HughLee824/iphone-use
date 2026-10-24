import Foundation

// Shared orchestration, exercised with event-recording doubles on the host.
// Only read-only geometry validation can repeat. Input and target selection never replay.
final class RunnerTextTransaction {
    struct Events {
        let focus: () throws -> Void
        let position: () throws -> Void
        let sendText: (String) throws -> Void
    }

    struct Validation<State> {
        let read: (Bool) throws -> State
        let isEmpty: (State) -> Bool
        let resultMatches: (State, String) -> Bool
    }

    struct Plan {
        let replacing: Bool
        let deletion: String
        let insertion: String
    }

    enum Failure: String, Error {
        case clearUnconfirmed = "replace_clear_unconfirmed"
        case resultUnconfirmed = "text_result_unconfirmed"
        case geometryUnsettled = "text_geometry_unsettled"
    }

    private(set) var stage = "validating"
    private(set) var focusAttempted = false
    private(set) var focusCompleted = false
    private(set) var keyboardEventsAttempted = 0
    private(set) var clearConfirmed = false
    private(set) var insertionAttempted = false
    private(set) var insertionAcknowledged = false
    private(set) var convergenceReads = 0
    private(set) var geometryRetries = 0
    private(set) var convergenceTimedOut = false
    private(set) var convergenceElapsedMs: Double = 0

    private let now: () -> TimeInterval
    private let pause: (TimeInterval) -> Void

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pause: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) {
        self.now = now
        self.pause = pause
    }

    var facts: [String: Any] {
        ["stage": stage, "focusAttempted": focusAttempted, "focusCompleted": focusCompleted,
         "keyboardEventsAttempted": keyboardEventsAttempted, "clearConfirmed": clearConfirmed,
         "insertionAttempted": insertionAttempted, "insertionAcknowledged": insertionAcknowledged,
         "convergenceReads": convergenceReads, "geometryRetries": geometryRetries,
         "convergenceTimedOut": convergenceTimedOut,
         "convergenceElapsedMs": convergenceElapsedMs,
         "automaticReplayAllowed": false]
    }

    private func converged<State>(_ read: () throws -> State) throws -> State {
        let began = now()
        let deadline = began + 5
        defer { convergenceElapsedMs = max(0, now() - began) * 1000 }
        for attempt in 0..<6 {
            convergenceReads += 1
            do {
                let state = try read()
                guard now() <= deadline else { break }
                return state
            } catch RunnerAXTree.Failure.geometryChanged {
                guard attempt < 5, now() < deadline else { break }
                pause(min(0.1, max(0, deadline - now())))
                guard now() < deadline else { break }
                geometryRetries += 1
            }
        }
        convergenceTimedOut = true
        throw Failure.geometryUnsettled
    }

    func run<State>(
        initial: State, needsFocus: Bool, events: Events,
        validation: Validation<State>, plan: (State) throws -> Plan
    ) throws -> State {
        // Reject unsupported values before focus can mutate the page.
        _ = try plan(initial)
        if needsFocus {
            stage = "focusing"
            focusAttempted = true
            try events.focus()
            focusCompleted = true
        }
        stage = "validating_after_focus"
        var current = try needsFocus ? converged { try validation.read(false) } : validation.read(false)
        let prepared = try plan(current)
        if prepared.replacing {
            if !prepared.deletion.isEmpty {
                stage = "positioning"
                keyboardEventsAttempted += 1
                try events.position()
                current = try converged { try validation.read(false) }
                stage = "clearing"
                keyboardEventsAttempted += 1
                try events.sendText(prepared.deletion)
            }
            stage = "verifying_clear"
            current = try converged { try validation.read(true) }
            guard validation.isEmpty(current) else { throw Failure.clearUnconfirmed }
            clearConfirmed = true
        }
        // Fresh identity/path validation immediately before insertion; if an
        // external edit followed clearing, do not overwrite it or repeat clearing.
        stage = "validating_before_insert"
        current = try validation.read(prepared.replacing)
        if prepared.replacing && !validation.isEmpty(current) { throw Failure.clearUnconfirmed }
        if !prepared.insertion.isEmpty {
            stage = "inserting"
            insertionAttempted = true
            keyboardEventsAttempted += 1
            try events.sendText(prepared.insertion)
            insertionAcknowledged = true
        }
        stage = "verifying_result"
        current = try converged { try validation.read(true) }
        if prepared.replacing && !validation.resultMatches(current, prepared.insertion) {
            throw Failure.resultUnconfirmed
        }
        stage = "completed"
        return current
    }
}
