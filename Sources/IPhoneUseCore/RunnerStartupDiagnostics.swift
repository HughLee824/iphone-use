import Foundation

// No IDE log exists in standalone mode. Report observed liveness only, never
// infer a passcode prompt or WLAN denial from a failed readiness check.
enum RunnerStartupDiagnostics {
    static func failure(processExited: Bool, authorization: [String: Any] = [:]) -> IPhoneUseError {
        let observation = processExited
            ? "The standalone Runner exited before USB readiness."
            : "Standalone Runner did not become ready over USB within 90 seconds."
        if authorization["authorization"] as? String == "required",
           authorization["evidence"] as? String == "device_log_exact_runner_pid" {
            return IPhoneUseError("runner_authorization_incomplete", observation +
                " The device requested Enable UI Automation for this Runner, and completion was not observed. Check the iPhone and complete authentication there; never send a passcode to the agent. After this attempt has exited and cleanup is confirmed, retry only when the user is ready.")
        }
        return IPhoneUseError("runner_start_failed", observation +
            " Inspect device XCTest logs and any actual phone prompt; this failure alone does not establish an authorization problem." +
            " If Enable UI Automation appears on the iPhone, complete authentication there; do not share the passcode." +
            " No launch retry or WLAN permission change was performed. See backend.json and exit.json (or startup-cleanup.json) in the session directory.")
    }
}
