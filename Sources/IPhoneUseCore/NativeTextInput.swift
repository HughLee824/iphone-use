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
    private var finalPreflightDeadline: TimeInterval?

    init(captured: TimeInterval, now: TimeInterval, policy: Policy) throws {
        guard captured.isFinite, now.isFinite, captured >= 0, captured <= now,
              policy != .system || now - captured <= 30 else {
            throw ActionFailure(code: "stale_observation", description: "Observation time is invalid or expired; observe again before input",
                                possiblyExecuted: false, requiresObservation: true)
        }
        self.policy = policy
        observationAgeSeconds = now - captured
        switch policy {
        case .coordinateGesture: dispatchDeadline = now + 8
        case .keyboard: dispatchDeadline = now + 30
        case .system: dispatchDeadline = captured + 30
        }
    }

    mutating func preflightDeadline(now: TimeInterval) -> TimeInterval {
        let deadline = min(dispatchDeadline, now + 8)
        finalPreflightDeadline = deadline
        return deadline
    }

    func checkBeforeDispatch(now: TimeInterval) throws {
        // Clipboard ownership checks after the last capture share that capture's
        // budget. They cannot leave a matching but now-old frame fit for dispatch.
        guard let finalPreflightDeadline, now.isFinite,
              now < min(dispatchDeadline, finalPreflightDeadline) else {
            throw ActionFailure(code: "stale_observation", description: "Input validation deadline expired; observe again before input",
                                possiblyExecuted: false, requiresObservation: true, result: ["inputTiming": result])
        }
    }

    var result: [String: Any] {
        ["policy": policy == .system ? "observation_expiry" : "current_observation_revalidation",
         "observationAgeAtAdmissionSeconds": observationAgeSeconds,
         "preflightBudgetSeconds": 8,
         "requestBudgetSeconds": policy == .keyboard ? 30 : (policy == .coordinateGesture ? 8 : 30)]
    }
}

enum NativeTextPhaseSchedule {
    static func delay(attempt: Int, started: TimeInterval, now: TimeInterval, deadline: TimeInterval) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        let offsets = [0.0, 0.19, 0.47, 0.83, 1.31, 1.97]
        let gaps = [0.0, 0.07, 0.13, 0.19, 0.11, 0.23]
        return max(0, min(deadline, max(started + offsets[attempt - 1], now + gaps[attempt - 1])) - now)
    }
}

// Retry observations only, never input. Every frame compares with the original
// guard, with unchanged thresholds and one shared deadline for this preflight.
enum NativeInputPreflight {
    static func check(guard screenGuard: ScreenGuard, displayID: UInt64?, displayRotation: String? = nil, captureSource: String? = nil, deadline: TimeInterval, maximumCaptures: Int,
                      fieldGuard: NativeTextFieldGuard? = nil, phaseMatcher: NativeTextPhaseMatcher? = nil, phaseSampling: Bool = false,
                      wait: (TimeInterval) throws -> Void = { Thread.sleep(forTimeInterval: $0) },
                      now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                      record: ([String: Any]) -> Void = { _ in },
                      capture: () throws -> CapturedObservation) throws -> (ScreenGuard.Check, Int) {
        guard (1...6).contains(maximumCaptures), deadline.isFinite else { throw ScreenGuard.Failure.invalidGuard }
        let started = now()
        let matcher = phaseMatcher ?? fieldGuard.map { NativeTextPhaseMatcher(field: $0) }
        var actualCaptures = 0
        for attempt in 1...maximumCaptures {
            guard now() < deadline else { throw IPhoneUseError("stale_observation", "Input observation deadline expired") }
            if phaseSampling, attempt > 1 {
                // Cover ~2 seconds with fast capture; stagger slow captures too,
                // rather than sampling a periodic blink at one fixed phase.
                try wait(NativeTextPhaseSchedule.delay(attempt: attempt, started: started, now: now(), deadline: deadline))
                guard now() < deadline else { throw IPhoneUseError("stale_observation", "Input observation deadline expired") }
            }
            let captureStarted = now()
            let frame = try capture()
            let phaseSamples = (frame.metadata["mediaSnapshot"] as? [String: Any])?["textPhaseSamples"] as? [[String: Any]] ?? []
            actualCaptures += max(1, phaseSamples.count)
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
            do {
                guard frame.metadata["displayID"] as? UInt64 == displayID,
                      let raw = frame.metadata["screenContext"] as? [String: Any] else { throw ScreenGuard.Failure.contextChanged }
                if let displayRotation {
                    guard frame.metadata["displayRotation"] as? String == displayRotation,
                          frame.metadata["nativeRotation"] as? String == "rot0" else { throw ScreenGuard.Failure.contextChanged }
                }
                context = try JSONDecoder().decode(ScreenContext.self, from: jsonData(raw))
                check = try screenGuard.check(png: frame.screenshot, context: context)
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
            if let matcher {
                check.apply(try matcher.check(png: frame.screenshot, context: context))
            }
            let checkedAt = now()
            let inTime = checkedAt < deadline
            record(["attempt": attempt, "elapsedMs": (checkedAt - started) * 1000,
                    "captureAndCheckMs": (checkedAt - captureStarted) * 1000,
                    "captureSource": frame.metadata["captureSource"] ?? "unknown",
                    "captureTimingsMs": frame.metadata["captureTimingsMs"] ?? [:],
                    "orientationRevalidated": frame.metadata["orientationRevalidated"] as? Bool ?? false,
                    "screenGuard": check.result, "inTime": inTime, "phaseSampling": phaseSampling || !phaseSamples.isEmpty, "mediaPhaseSamples": phaseSamples])
            if check.accepted && inTime { return (check, actualCaptures) }
            if attempt == maximumCaptures || !inTime || check.screenChange > check.policy.maxScreenChange {
                throw ActionFailure(code: "stale_observation", description: "Screen guard or deadline rejected input; inspect the attached pre-input image",
                    possiblyExecuted: false, requiresObservation: true,
                    result: ["screenGuard": check.result, "preInputCaptures": actualCaptures, "preInputDeadlineExceeded": !inTime], rejectedCapture: frame)
            }
        }
        throw ScreenGuard.Failure.invalidGuard
    }
}
