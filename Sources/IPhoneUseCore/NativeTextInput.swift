import Foundation

enum NativeTextInput {
    case keyboard([[UInt8]])
    case pasteboard(String)
    case clear

    init(text: String, mode: String, method: String = "auto") throws {
        guard ["auto", "keys", "paste"].contains(method) else { throw IPhoneUseError("invalid_text_method", "Use --method auto, keys or paste") }
        _ = try NativeKeyboard.editingKeys(mode: mode)
        if text.isEmpty, mode == "replace" { self = .clear; return }
        guard !text.isEmpty, text.utf8.count <= TextInput.maximumBytes,
              text.unicodeScalars.allSatisfy({
                  let value = $0.value
                  if method != "keys" && (value == 10 || value == 13) { return true }
                  return value >= 32 && !(127...159).contains(value) && value != 0x2028 && value != 0x2029 && !(0xF700...0xF8FF).contains(value)
              }) else { throw IPhoneUseError("native_text_unsupported", "Use 1...4096 UTF-8 bytes without control keys; LF/CR require auto or paste") }
        // Even ASCII line breaks are pasted literally, never sent as Return.
        if method == "keys" || (method == "auto" && text.utf8.allSatisfy({ (32...126).contains($0) })) { self = .keyboard(try NativeKeyboard.keys(for: text, mode: "insert")) }
        else { self = .pasteboard(text) }
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
              policy != .system || now - captured <= 30 else {
            throw ActionFailure(code: "stale_observation", description: "Observation time is invalid or expired; observe again before input",
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
            throw IPhoneUseError("input_preflight_timeout", "Input preparation expired or exhausted its capture phases")
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
              now < budget.deadline else {
            throw ActionFailure(code: "stale_observation", description: "Input validation deadline expired; observe again before input",
                                possiblyExecuted: false, requiresObservation: true, result: ["inputTiming": result])
        }
    }

    var result: [String: Any] {
        ["policy": policy == .system ? "observation_expiry" : "current_observation_revalidation",
         "observationAgeAtAdmissionSeconds": observationAgeSeconds,
         "preflightBudgetSeconds": 8,
         "requestBudgetSeconds": 30,
         "preflightBudgetStartsAt": "apple_png_request",
         "capturePhases": capturePhases]
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
        purpose == .input ? min(requestDeadline, validationStartedAt.map { $0 + 8 } ?? requestDeadline) : requestDeadline
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
            throw IPhoneUseError("input_preflight_timeout", validationStartedAt == nil
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

// Native text checks one fresh image against the original observation.
enum NativeInputPreflight {
    static func check(guard screenGuard: ScreenGuard, displayID: UInt64?, displayRotation: String? = nil, captureSource: String? = nil, deadline: TimeInterval, maximumCaptures: Int,
                      fieldGuard: NativeTextFieldGuard? = nil, caretGuard: NativeBoundCaretGuard? = nil,
                      budget: NativeCaptureBudget? = nil,
                      now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                      record: ([String: Any]) -> Void = { _ in },
                      capture: () throws -> CapturedObservation) throws -> (ScreenGuard.Check, Int) {
        guard (1...6).contains(maximumCaptures), deadline.isFinite else { throw ScreenGuard.Failure.invalidGuard }
        let started = now()
        let capturesLimit = fieldGuard == nil ? maximumCaptures : 1
        var actualCaptures = 0
        for attempt in 1...capturesLimit {
            guard now() < deadline else { throw IPhoneUseError("stale_observation", "Input observation deadline expired") }
            let captureStarted = now()
            let frame: CapturedObservation
            do { frame = try capture() }
            catch {
                record(["attempt": attempt, "captureError": (error as? IPhoneUseError)?.code ?? "capture_failed",
                        "captureDiagnostics": (error as? IPhoneUseError)?.diagnostics ?? [:],
                        "phase": budget?.validationStartedAt == nil ? "preparation" : "apple_png_validation",
                        "elapsedMs": (now() - started) * 1000])
                throw error
            }
            actualCaptures += 1
            if frame.metadata["orientationResynchronized"] as? Bool == true {
                throw ActionFailure(code: "stale_observation", description: "Media orientation was resynchronized; inspect the new observation before choosing coordinates",
                    possiblyExecuted: false, requiresObservation: true,
                    result: ["preInputCaptures": actualCaptures, "orientationResynchronized": true], rejectedCapture: frame)
            }
            if let captureSource, frame.metadata["captureSource"] as? String != captureSource {
                record(["attempt": attempt, "captureSourceChanged": true,
                        "captureSource": frame.metadata["captureSource"] ?? "unknown",
                        "captureTimingsMs": frame.metadata["captureTimingsMs"] ?? [:],
                        "elapsedMs": (now() - started) * 1000])
                throw ActionFailure(code: "stale_observation", description: "Screenshot source changed; inspect the new observation before choosing an action",
                    possiblyExecuted: false, requiresObservation: true,
                    result: ["preInputCaptures": actualCaptures, "captureSourceChanged": true], rejectedCapture: frame)
            }
            let context: ScreenContext
            var check: ScreenGuard.Check
            var fieldRejection: String?
            do {
                guard frame.metadata["displayID"] as? UInt64 == displayID,
                      let raw = frame.metadata["screenContext"] as? [String: Any] else { throw ScreenGuard.Failure.contextChanged }
                if let displayRotation {
                    guard frame.metadata["displayRotation"] as? String == displayRotation,
                          frame.metadata["nativeRotation"] as? String == "rot0" else { throw ScreenGuard.Failure.contextChanged }
                }
                context = try JSONDecoder().decode(ScreenContext.self, from: jsonData(raw))
                let image = try ScreenImage(png: frame.screenshot)
                let comparisonImage: ScreenImage
                if let fieldGuard, let caretGuard {
                    comparisonImage = try fieldGuard.screenComparisonImage(image, caret: caretGuard, context: context)
                } else { comparisonImage = image }
                check = try screenGuard.check(image: comparisonImage, context: context)
                if let fieldGuard {
                    let current = try fieldGuard.pixels(png: frame.screenshot, context: context, decodedImage: image)
                    let match = fieldGuard.compare(current, caret: caretGuard)
                    check.apply(match, caret: caretGuard)
                    if match == .none { fieldRejection = fieldGuard.rejection(current, caret: caretGuard) }
                }
            } catch ScreenGuard.Failure.contextChanged {
                // An orientation change is never a retryable pixel mismatch. Preserve
                // this new frame and invalidate the old observation before any input.
                record(["attempt": attempt, "contextChanged": true,
                        "captureSource": frame.metadata["captureSource"] ?? "unknown",
                        "captureTimingsMs": frame.metadata["captureTimingsMs"] ?? [:],
                        "elapsedMs": (now() - started) * 1000])
                throw ActionFailure(code: "stale_observation", description: "Display geometry or orientation changed; inspect the new screenshot before choosing coordinates",
                    possiblyExecuted: false, requiresObservation: true,
                    result: ["preInputCaptures": actualCaptures, "screenContextChanged": true], rejectedCapture: frame)
            }
            let checkedAt = now()
            let effectiveDeadline = min(deadline, budget?.deadline ?? deadline)
            let inTime = checkedAt < effectiveDeadline && (budget == nil || budget?.validationStartedAt != nil)
            record(["attempt": attempt, "elapsedMs": (checkedAt - started) * 1000,
                    "captureAndCheckMs": (checkedAt - captureStarted) * 1000,
                    "preparationMs": budget?.validationStartedAt.map { ($0 - started) * 1000 } as Any? ?? NSNull(),
                    "validationAndCheckMs": budget?.validationStartedAt.map { (checkedAt - $0) * 1000 } as Any? ?? NSNull(),
                    "captureSource": frame.metadata["captureSource"] ?? "unknown",
                    "captureTimingsMs": frame.metadata["captureTimingsMs"] ?? [:],
                    "orientationRevalidated": frame.metadata["orientationRevalidated"] as? Bool ?? false,
                    "orientationRecovery": frame.metadata["orientationRecovery"] ?? [:],
                    "screenGuard": check.result, "inTime": inTime,
                    "fieldRejection": fieldRejection ?? "none"])
            if check.accepted && inTime { return (check, actualCaptures) }
            if attempt == capturesLimit || !inTime || check.screenChange > check.policy.maxScreenChange {
                let reason = !inTime ? "input_preflight_timeout" : (fieldGuard == nil ? "stale_observation" :
                    (check.screenChange > check.policy.maxScreenChange ? "screen_changed" : fieldRejection ?? "text_field_changed"))
                let message = reason == "caret_confirmation_required"
                    ? "Inspect the attached image and confirm a visible caret with --caret-rect and --field-rect on its new oN; do not retry the old reference"
                    : "Input was not dispatched: \(reason). Inspect the attached image before choosing another action"
                throw ActionFailure(code: reason, description: message,
                    possiblyExecuted: false, requiresObservation: true,
                    result: ["screenGuard": check.result, "preInputCaptures": actualCaptures, "preInputDeadlineExceeded": !inTime], rejectedCapture: frame)
            }
        }
        throw ScreenGuard.Failure.invalidGuard
    }
}
