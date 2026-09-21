import Foundation

enum NativeTextInput {
    case keyboard([[UInt8]])
    case pasteboard(String)
    case clear

    init(text: String, mode: String, method: String = "auto") throws {
        guard ["auto", "keys", "paste"].contains(method) else { throw SomaError("invalid_text_method", "Use --method auto, keys or paste") }
        _ = try NativeKeyboard.editingKeys(mode: mode)
        if text.isEmpty, mode == "replace" { self = .clear; return }
        guard !text.isEmpty, text.utf8.count <= TextInput.maximumBytes,
              text.unicodeScalars.allSatisfy({
                  let value = $0.value
                  return value >= 32 && !(127...159).contains(value) && value != 0x2028 && value != 0x2029 && !(0xF700...0xF8FF).contains(value)
              }) else { throw SomaError("native_text_unsupported", "Use 1...4096 UTF-8 bytes without control keys or newlines") }
        if method == "keys" || (method == "auto" && text.utf8.allSatisfy({ $0 < 128 })) { self = .keyboard(try NativeKeyboard.keys(for: text, mode: "insert")) }
        else { self = .pasteboard(text) }
    }
    var usesPasteboard: Bool { if case .pasteboard = self { return true }; return false }
}

// Retry observations only, never input. Every frame compares with the original
// guard, with unchanged thresholds and one shared deadline for this preflight.
enum NativeInputPreflight {
    static func check(guard screenGuard: ScreenGuard, displayID: UInt64?, displayRotation: String? = nil, deadline: TimeInterval, maximumCaptures: Int,
                      caretGuard: NativeCaretGuard? = nil,
                      now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                      record: ([String: Any]) -> Void = { _ in },
                      capture: () throws -> CapturedObservation) throws -> (ScreenGuard.Check, Int) {
        guard (1...3).contains(maximumCaptures), deadline.isFinite else { throw ScreenGuard.Failure.invalidGuard }
        let started = now()
        for attempt in 1...maximumCaptures {
            guard now() < deadline else { throw SomaError("stale_observation", "Input observation deadline expired") }
            let captureStarted = now()
            let frame = try capture()
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
                        "elapsedMs": (now() - started) * 1000])
                throw ActionFailure(code: "stale_observation", description: "Display geometry or orientation changed; inspect the new screenshot before choosing coordinates",
                    possiblyExecuted: false, requiresObservation: true,
                    result: ["preInputCaptures": attempt, "screenContextChanged": true], rejectedCapture: frame)
            }
            if !check.accepted, check.screenChange <= check.policy.maxScreenChange,
               let caretGuard, try caretGuard.acceptsBlink(png: frame.screenshot, context: context) {
                check.ignoredCaretBlink = caretGuard.caret
            }
            let checkedAt = now()
            let inTime = checkedAt < deadline
            record(["attempt": attempt, "elapsedMs": (checkedAt - started) * 1000,
                    "captureAndCheckMs": (checkedAt - captureStarted) * 1000,
                    "screenGuard": check.result, "inTime": inTime])
            if check.accepted && inTime { return (check, attempt) }
            if attempt == maximumCaptures || !inTime || check.screenChange > check.policy.maxScreenChange {
                throw ActionFailure(code: "stale_observation", description: "Screen guard or deadline rejected input; inspect the attached pre-input image",
                    possiblyExecuted: false, requiresObservation: true,
                    result: ["screenGuard": check.result, "preInputCaptures": attempt, "preInputDeadlineExceeded": !inTime], rejectedCapture: frame)
            }
        }
        throw ScreenGuard.Failure.invalidGuard
    }
}
