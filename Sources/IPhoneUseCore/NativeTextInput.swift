import Foundation

enum NativeTextInput {
    case keyboard([[UInt8]])
    case pasteboard(String)
    case clear

    init(text: String, mode: String, method: String = "auto") throws {
        guard ["auto", "keys", "paste"].contains(method) else {
            throw IPhoneUseError("invalid_text_method", "Use --method auto, keys or paste")
        }
        _ = try NativeKeyboard.editingKeys(mode: mode)
        if text.isEmpty, mode == "replace" { self = .clear; return }
        guard !text.isEmpty, text.utf8.count <= TextInput.maximumBytes,
            text.unicodeScalars.allSatisfy({
                let value = $0.value
                if method != "keys" && (value == 10 || value == 13) { return true }
                return value >= 32 && !(127...159).contains(value) && value != 0x2028 && value != 0x2029
                    && !(0xF700...0xF8FF).contains(value)
            })
        else {
            throw IPhoneUseError(
                "native_text_unsupported",
                "Use 1...4096 UTF-8 bytes without control keys; LF/CR require auto or paste")
        }
        // Even ASCII line breaks are pasted literally, never sent as Return.
        if method == "keys" || (method == "auto" && text.utf8.allSatisfy({ (32...126).contains($0) })) {
            self = .keyboard(try NativeKeyboard.keys(for: text, mode: "insert"))
        } else {
            self = .pasteboard(text)
        }
    }
    var usesPasteboard: Bool { if case .pasteboard = self { return true }; return false }
}

// Current observations are comparison baselines. Agent thinking time is not an
// input lease: validate the same baseline again within bounded host-side phases.
struct NativeInputTiming {
    enum Policy { case coordinateGesture, keyboard, system }
    let observationAgeSeconds: TimeInterval
    let dispatchDeadline: TimeInterval
    let policy: Policy
    private var finalCaptureBudget: NativeCaptureBudget?
    private var capturePhases = 0

    init(captured: TimeInterval, now: TimeInterval, policy: Policy) throws {
        guard captured.isFinite, now.isFinite, captured >= 0, captured <= now,
            policy != .system || now - captured <= 30
        else {
            throw ActionFailure(
                code: "stale_observation",
                description: "Observation time is invalid or expired; observe again before input",
                possiblyExecuted: false, requiresObservation: true)
        }
        self.policy = policy
        observationAgeSeconds = now - captured
        switch policy {
        case .coordinateGesture: dispatchDeadline = now + 30
        case .keyboard: dispatchDeadline = now + 30
        case .system: dispatchDeadline = captured + 30
        }
    }

    mutating func captureBudget(now: TimeInterval) throws -> NativeCaptureBudget {
        guard now.isFinite, now < dispatchDeadline, capturePhases < (policy == .keyboard ? 2 : 1) else {
            throw IPhoneUseError(
                "input_preflight_timeout", "Input preparation expired or exhausted its capture phases")
        }
        capturePhases += 1
        let budget = NativeCaptureBudget(requestDeadline: dispatchDeadline)
        finalCaptureBudget = budget
        return budget
    }

    func checkBeforeDispatch(now: TimeInterval) throws {
        // Clipboard ownership checks after the last capture share that capture's
        // budget. They cannot leave a matching but now-old frame fit for dispatch.
        guard let budget = finalCaptureBudget, budget.validationStartedAt != nil, now.isFinite,
            now < budget.deadline
        else {
            throw ActionFailure(
                code: "stale_observation",
                description: "Input validation deadline expired; observe again before input",
                possiblyExecuted: false, requiresObservation: true, result: ["inputTiming": result])
        }
    }

    var result: [String: Any] {
        [
            "policy": policy == .system ? "observation_expiry" : "current_observation_revalidation",
            "observationAgeAtAdmissionSeconds": observationAgeSeconds,
            "preflightBudgetSeconds": 8,
            "requestBudgetSeconds": 30,
            "preflightBudgetStartsAt": "apple_png_request",
            "capturePhases": capturePhases
        ]
    }
}

// One preparation/capture phase. Apple reads may consult the deadline in parallel;
// validation starts only after those reads have joined and geometry is verified.
final class NativeCaptureBudget {
    enum Purpose { case input, observation }
    let requestDeadline: TimeInterval
    let purpose: Purpose
    private(set) var validationStartedAt: TimeInterval?
    var deadline: TimeInterval {
        purpose == .input
            ? min(requestDeadline, validationStartedAt.map { $0 + 8 } ?? requestDeadline) : requestDeadline
    }

    init(requestDeadline: TimeInterval, purpose: Purpose = .input) {
        self.requestDeadline = requestDeadline
        self.purpose = purpose
    }

    func check(now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        guard now.isFinite, requestDeadline.isFinite, now < deadline else {
            if purpose == .observation {
                throw IPhoneUseError("capture_timeout", "Observation exceeded its capture deadline")
            }
            throw IPhoneUseError(
                "input_preflight_timeout",
                validationStartedAt == nil
                    ? "Input preparation exceeded the request deadline"
                    : "Apple PNG validation exceeded its dispatch deadline")
        }
    }

    @discardableResult
    func beginValidation(now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> TimeInterval {
        try check(now: now)
        // A second call can never extend a frame's lifetime.
        if validationStartedAt == nil { validationStartedAt = now }
        return deadline
    }
}
