import IPhoneUseRunnerSupport
import Foundation

// Native text checks fresh images against the original observation.
struct NativeInputPreflight {
    let screenGuard: ScreenGuard
    let displayID: UInt64?
    let displayRotation: String?
    let captureSource: String?
    let deadline: TimeInterval
    let maximumCaptures: Int
    let fieldGuard: NativeTextFieldGuard?
    let caretGuard: NativeBoundCaretGuard?
    let budget: NativeCaptureBudget?
    static func check(
        guard screenGuard: ScreenGuard, displayID: UInt64?, displayRotation: String? = nil,
        captureSource: String? = nil, deadline: TimeInterval, maximumCaptures: Int,
        fieldGuard: NativeTextFieldGuard? = nil, caretGuard: NativeBoundCaretGuard? = nil,
        budget: NativeCaptureBudget? = nil, now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        record: ([String: Any]) -> Void = { _ in }, capture: () throws -> CapturedObservation
    ) throws -> (ScreenGuard.Check, Int) {
        try Self(
            screenGuard: screenGuard, displayID: displayID, displayRotation: displayRotation,
            captureSource: captureSource, deadline: deadline, maximumCaptures: maximumCaptures, fieldGuard: fieldGuard,
            caretGuard: caretGuard, budget: budget
        ).run(now: now, record: record, capture: capture)
    }

    private func run(
        now: () -> TimeInterval, record: ([String: Any]) -> Void, capture: () throws -> CapturedObservation
    ) throws -> (ScreenGuard.Check, Int) {
        guard (1...6).contains(maximumCaptures), deadline.isFinite else { throw ScreenGuard.Failure.invalidGuard }
        let started = now()
        let capturesLimit = fieldGuard == nil ? maximumCaptures : 1
        var actualCaptures = 0
        for attempt in 1...capturesLimit {
            guard now() < deadline else {
                throw IPhoneUseError("stale_observation", "Input observation deadline expired")
            }
            let captureStarted = now()
            let frame = try captureFrame(attempt: attempt, started: started, now: now, record: record, capture: capture)
            actualCaptures += 1
            try validateSource(
                frame, actualCaptures: actualCaptures, attempt: attempt, elapsed: { (now() - started) * 1000 },
                record: record)
            let check: ScreenGuard.Check
            let fieldRejection: String?
            do { (check, fieldRejection) = try compare(frame) } catch ScreenGuard.Failure.contextChanged {
                // An orientation change is never a retryable pixel mismatch. Preserve
                // this new frame and invalidate the old observation before any input.
                record([
                    "attempt": attempt, "contextChanged": true,
                    "captureSource": frame.metadata["captureSource"] ?? "unknown",
                    "captureTimingsMs": frame.metadata["captureTimingsMs"] ?? [:], "elapsedMs": (now() - started) * 1000
                ])
                throw ActionFailure(
                    code: "stale_observation",
                    description:
                        """
                        Display geometry or orientation changed; inspect the new\
                         screenshot before choosing coordinates
                        """,
                    possiblyExecuted: false, requiresObservation: true,
                    result: ["preInputCaptures": actualCaptures, "screenContextChanged": true], rejectedCapture: frame)
            }
            let checkedAt = now()
            let effectiveDeadline = min(deadline, budget?.deadline ?? deadline)
            let inTime = checkedAt < effectiveDeadline && (budget == nil || budget?.validationStartedAt != nil)
            record(
                comparisonFacts(
                    frame, check: check, fieldRejection: fieldRejection, timing: (started, captureStarted),
                    sample: Sample(attempt: attempt, checkedAt: checkedAt, inTime: inTime)))
            if check.accepted && inTime { return (check, actualCaptures) }
            if attempt == capturesLimit || !inTime || check.screenChange > check.policy.maxScreenChange {
                throw rejection(
                    check, inTime: inTime, fieldRejection: fieldRejection, actualCaptures: actualCaptures, frame: frame)
            }
        }
        throw ScreenGuard.Failure.invalidGuard
    }

    private struct Sample {
        let attempt: Int
        let checkedAt: TimeInterval
        let inTime: Bool
    }

    private func comparisonFacts(
        _ frame: CapturedObservation, check: ScreenGuard.Check, fieldRejection: String?,
        timing: (TimeInterval, TimeInterval), sample: Sample
    ) -> [String: Any] {
        let started = timing.0, captureStarted = timing.1
        return [
            "attempt": sample.attempt, "elapsedMs": (sample.checkedAt - started) * 1000,
            "captureAndCheckMs": (sample.checkedAt - captureStarted) * 1000,
            "preparationMs": budget?.validationStartedAt.map { ($0 - started) * 1000 } as Any? ?? NSNull(),
            "validationAndCheckMs": budget?.validationStartedAt.map { (sample.checkedAt - $0) * 1000 } as Any?
                ?? NSNull(), "captureSource": frame.metadata["captureSource"] ?? "unknown",
            "captureTimingsMs": frame.metadata["captureTimingsMs"] ?? [:],
            "orientationRevalidated": frame.metadata["orientationRevalidated"] as? Bool ?? false,
            "orientationRecovery": frame.metadata["orientationRecovery"] ?? [:], "screenGuard": check.result,
            "inTime": sample.inTime, "fieldRejection": fieldRejection ?? "none"
        ]
    }

    private func captureFrame(
        attempt: Int, started: TimeInterval, now: () -> TimeInterval, record: ([String: Any]) -> Void,
        capture: () throws -> CapturedObservation
    ) throws -> CapturedObservation {
        let frame: CapturedObservation
        do { frame = try capture() } catch {
            record([
                "attempt": attempt, "captureError": (error as? IPhoneUseError)?.code ?? "capture_failed",
                "captureDiagnostics": (error as? IPhoneUseError)?.diagnostics ?? [:],
                "phase": budget?.validationStartedAt == nil ? "preparation" : "apple_png_validation",
                "elapsedMs": (now() - started) * 1000
            ])
            throw error
        }
        return frame
    }

    private func validateSource(
        _ frame: CapturedObservation, actualCaptures: Int, attempt: Int, elapsed: () -> Double,
        record: ([String: Any]) -> Void
    ) throws {
        if frame.metadata["orientationResynchronized"] as? Bool == true {
            throw ActionFailure(
                code: "stale_observation",
                description:
                    "Media orientation was resynchronized; inspect the new observation before choosing coordinates",
                possiblyExecuted: false, requiresObservation: true,
                result: ["preInputCaptures": actualCaptures, "orientationResynchronized": true], rejectedCapture: frame)
        }
        if let captureSource, frame.metadata["captureSource"] as? String != captureSource {
            record([
                "attempt": attempt, "captureSourceChanged": true,
                "captureSource": frame.metadata["captureSource"] ?? "unknown",
                "captureTimingsMs": frame.metadata["captureTimingsMs"] ?? [:], "elapsedMs": elapsed()
            ])
            throw ActionFailure(
                code: "stale_observation",
                description: "Screenshot source changed; inspect the new observation before choosing an action",
                possiblyExecuted: false, requiresObservation: true,
                result: ["preInputCaptures": actualCaptures, "captureSourceChanged": true], rejectedCapture: frame)
        }
    }

    private func compare(_ frame: CapturedObservation) throws -> (ScreenGuard.Check, String?) {
        let context: ScreenContext
        var check: ScreenGuard.Check
        var fieldRejection: String?
        guard frame.metadata["displayID"] as? UInt64 == displayID,
            let raw = frame.metadata["screenContext"] as? [String: Any]
        else { throw ScreenGuard.Failure.contextChanged }
        if let displayRotation {
            guard frame.metadata["displayRotation"] as? String == displayRotation,
                frame.metadata["nativeRotation"] as? String == "rot0"
            else { throw ScreenGuard.Failure.contextChanged }
        }
        context = try JSONDecoder().decode(ScreenContext.self, from: jsonData(raw))
        let image = try ScreenImage(png: frame.screenshot)
        let comparisonImage: ScreenImage
        if let fieldGuard, let caretGuard {
            comparisonImage = try fieldGuard.screenComparisonImage(image, caret: caretGuard, context: context)
        } else {
            comparisonImage = image
        }
        check = try screenGuard.check(image: comparisonImage, context: context)
        if let fieldGuard {
            let current = try fieldGuard.pixels(png: frame.screenshot, context: context, decodedImage: image)
            let match = fieldGuard.compare(current, caret: caretGuard)
            check.apply(match, caret: caretGuard)
            if match == .none { fieldRejection = fieldGuard.rejection(current, caret: caretGuard) }
        }
        return (check, fieldRejection)
    }

    private func rejection(
        _ check: ScreenGuard.Check, inTime: Bool, fieldRejection: String?, actualCaptures: Int,
        frame: CapturedObservation
    ) -> ActionFailure {
        let reason =
            !inTime
            ? "input_preflight_timeout"
            : (fieldGuard == nil
                ? "stale_observation"
                : (check.screenChange > check.policy.maxScreenChange
                    ? "screen_changed" : fieldRejection ?? "text_field_changed"))
        let message =
            reason == "caret_confirmation_required"
            ? """
            Inspect the attached image and confirm a visible caret with --caret-rect and --field-rect\
             on its new oN; do not retry the old reference
            """ : "Input was not dispatched: \(reason). Inspect the attached image before choosing another action"
        return ActionFailure(
            code: reason, description: message, possiblyExecuted: false, requiresObservation: true,
            result: [
                "screenGuard": check.result, "preInputCaptures": actualCaptures, "preInputDeadlineExceeded": !inTime
            ], rejectedCapture: frame)
    }
}
