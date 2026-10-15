import Foundation

// No IDE log exists in standalone mode. Report observed liveness only, never
// infer a passcode prompt or WLAN denial from a failed readiness check.
enum RunnerStartupDiagnostics {
    static func failure(processExited: Bool) -> IPhoneUseError {
        let observation = processExited
            ? "The standalone Runner exited before USB readiness."
            : "Standalone Runner did not become ready over USB within 90 seconds."
        return IPhoneUseError("runner_start_failed", observation +
            " Inspect device XCTest logs and any actual phone prompt; this failure alone does not establish an authorization problem." +
            " No launch retry or WLAN permission change was performed. See backend.json and startup-cleanup.json in the session directory.")
    }
}
