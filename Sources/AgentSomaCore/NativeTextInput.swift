import Foundation

enum NativeTextInput {
    case keyboard([[UInt8]])
    case pasteboard(String)

    init(text: String, mode: String, method: String = "auto") throws {
        guard ["auto", "keys", "paste"].contains(method) else { throw SomaError("invalid_text_method", "Use --method auto, keys or paste") }
        guard mode == "insert" else { throw SomaError("native_text_unsupported", "Native typing supports insert only") }
        guard !text.isEmpty, text.utf8.count <= TextInput.maximumBytes,
              text.unicodeScalars.allSatisfy({
                  let value = $0.value
                  return value >= 32 && !(127...159).contains(value) && value != 0x2028 && value != 0x2029 && !(0xF700...0xF8FF).contains(value)
              }) else { throw SomaError("native_text_unsupported", "Use 1...4096 UTF-8 bytes without control keys or newlines") }
        if method == "keys" || (method == "auto" && text.utf8.allSatisfy({ $0 < 128 })) { self = .keyboard(try NativeKeyboard.keys(for: text, mode: mode)) }
        else { self = .pasteboard(text) }
    }
    var usesPasteboard: Bool { if case .pasteboard = self { return true }; return false }
}

// Retry observations only, never input. Every frame compares with the original
// guard, with unchanged thresholds and one shared deadline for this preflight.
enum NativeInputPreflight {
    static func check(guard screenGuard: ScreenGuard, displayID: UInt64?, deadline: TimeInterval, maximumCaptures: Int,
                      now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                      capture: () throws -> CapturedObservation) throws -> (ScreenGuard.Check, Int) {
        guard (1...3).contains(maximumCaptures), deadline.isFinite else { throw ScreenGuard.Failure.invalidGuard }
        for attempt in 1...maximumCaptures {
            guard now() < deadline else { throw SomaError("stale_observation", "Input observation deadline expired") }
            let frame = try capture()
            guard frame.metadata["displayID"] as? UInt64 == displayID,
                  let raw = frame.metadata["screenContext"] as? [String: Any] else { throw ScreenGuard.Failure.contextChanged }
            let context = try JSONDecoder().decode(ScreenContext.self, from: jsonData(raw))
            let check = try screenGuard.check(png: frame.screenshot, context: context)
            let inTime = now() < deadline
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
