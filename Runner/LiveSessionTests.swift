import IPhoneUseRunnerSupport
import Network
import XCTest
import Darwin

struct CommandError: Error, CustomStringConvertible {
    let code: String
    let description: String
    let requiresObservation: Bool
    init(_ code: String, requiresObservation: Bool = false, message: String? = nil) {
        self.code = code
        self.description = message ?? code
        self.requiresObservation = requiresObservation
    }
}

final class LiveSessionTests: XCTestCase {
    var currentApp: XCUIApplication?
    var currentBundleID: String?
    private var commandIssues: [String] = []
    private var handlingCommand = false
    private var inputProgress: (() -> Void)?
    var executionStarted = false
    var inputCompleted = false
    var inputSessionUncertain = false
    var lifecycleFacts: [String: Any]?
    var observedReferences = RunnerAXReferences<NSObject>()
    var commandReferences = RunnerAXReferences<NSObject>()
    var textTransaction: RunnerTextTransaction?
    let stateTimeout = XCTestStateTimeout()
    var postInputTextFields: [ScreenRect] = []
    var postInputContext: ScreenContext?
    var frameStability: FrameStability?
    struct ActionFrame {
        let png: Data
        let capturedAt: Double
        let fingerprint: FrameFingerprint
    }
    var actionFrame: ActionFrame?
    var screenGuardResult: [String: Any]?

    override func record(_ issue: XCTIssue) {
        if handlingCommand { commandIssues.append(issue.compactDescription) } else { super.record(issue) }
    }

    @MainActor
    func testCommandSession() async throws {
        RunnerStartupGuard.finish()
        guard let token = ProcessInfo.processInfo.environment["IPHONE_USE_SESSION_TOKEN"], token.count >= 32
        else {
            throw XCTSkip("Start through iphone-use connect to enable the command session", file: #fileID)
        }
        continueAfterFailure = true
        let server = try CommandServer()
        let sessionID = UUID().uuidString
        let started = ProcessInfo.processInfo.systemUptime
        var sequence = 0
        var didShutdown = false
        let hostManaged = ProcessInfo.processInfo.environment["IPHONE_USE_HOST_MANAGED"] == "1"
        let expiry: Task<Void, Never>? =
            hostManaged
            ? nil
            : Task {
                try? await Task.sleep(nanoseconds: 900_000_000_000)
                if !Task.isCancelled { server.stop() }
            }
        defer { expiry?.cancel(); server.stop() }

        for await request in server.requests {
            sequence += 1
            resetCommand()
            let began = ProcessInfo.processInfo.systemUptime
            let command = request.body
            var response: [String: Any] = [
                "id": command["id"] ?? NSNull(), "sessionId": sessionID,
                "runnerPid": ProcessInfo.processInfo.processIdentifier, "sequence": sequence,
                "uptimeMs": (began - started) * 1000
            ]
            let stopping = await executeRequest(
                request, server: server, token: token,
                sessionID: sessionID, response: &response)
            completeCommand(command, response: &response)
            response["runnerMs"] = (ProcessInfo.processInfo.systemUptime - began) * 1000
            try await server.reply(response, to: request)
            print(
                """
                IPHONE_USE_COMMAND id=\(command["id"] ?? "missing") sequence=\(sequence)\
                 op=\(command["op"] ?? "missing") ok=\(response["ok"] ?? false)\
                 runnerMs=\(response["runnerMs"] ?? 0) beganUptime=\(began)\
                 repliedUptime=\(ProcessInfo.processInfo.systemUptime)
                """
            )
            if stopping { didShutdown = true; break }
        }
        XCTAssertTrue(didShutdown, "Session ended without an explicit shutdown command", file: #fileID)
    }

    private func resetCommand() {
        commandIssues = []
        handlingCommand = true
        lifecycleFacts = nil
        commandReferences = RunnerAXReferences()
        textTransaction = nil
        executionStarted = false
        inputProgress = nil
        inputCompleted = false
        postInputTextFields = []
        postInputContext = nil
        frameStability = nil
        actionFrame = nil
        screenGuardResult = nil
    }

    @MainActor
    private func executeRequest(
        _ request: CommandServer.Request, server: CommandServer, token: String,
        sessionID: String, response: inout [String: Any]
    ) async -> Bool {
        let command = request.body
        var stopping = false
        do {
            guard command["token"] as? String == token else { throw CommandError("unauthorized") }
            if command["op"] as? String == "act", command["inputProgress"] as? Bool == true {
                inputProgress = {
                    server.progress(
                        [
                            "id": command["id"] ?? NSNull(), "sessionId": sessionID,
                            "event": "input_started"
                        ], to: request)
                }
            }
            response["result"] = try await execute(command)
            try checkIssues()
            response["ok"] = true
            stopping = command["op"] as? String == "shutdown"
        } catch {
            response["ok"] = false
            response["error"] = String(describing: error)
            response["errorCode"] = (error as? CommandError)?.code ?? "xctest_error"
            response["requiresObservation"] = (error as? CommandError)?.requiresObservation ?? true
        }
        return stopping
    }

    private func completeCommand(_ command: [String: Any], response: inout [String: Any]) {
        inputProgress = nil
        handlingCommand = false
        if ["launch", "app-lifecycle"].contains(command["op"] as? String ?? "") {
            if let lifecycleFacts { response["result"] = lifecycleFacts }
            response["execution"] = [
                "started": executionStarted, "completed": response["ok"] as? Bool == true
            ]
        }
        if command["op"] as? String == "act" {
            if let textTransaction {
                var result = response["result"] as? [String: Any] ?? [:]
                result["textExecution"] = textTransaction.facts
                response["result"] = result
            }
            response["execution"] = [
                "started": executionStarted, "inputCompleted": inputCompleted,
                "completed": response["ok"] as? Bool == true
            ]
            response["stability"] = frameStability?.result
            if response["ok"] as? Bool == false, let reference = frameStability?.comparisonReferencePNG {
                response["stabilityReferenceBase64"] = reference.base64EncodedString()
            }
            response["screenGuard"] = screenGuardResult
            if let frame = actionFrame {
                response["frame"] = [
                    "screenshotBase64": frame.png.base64EncodedString(),
                    "capturedAt": frame.capturedAt, "hash": frame.fingerprint.hash,
                    "width": frame.fingerprint.width, "height": frame.fingerprint.height
                ]
            }
        }
    }

    func checkIssues() throws {
        if !commandIssues.isEmpty {
            throw CommandError("xctest_error", message: commandIssues.joined(separator: "\n"))
        }
    }

    func publishInputStarted() {
        let notify = inputProgress
        inputProgress = nil
        notify?()
    }

    @MainActor
    func event(_ body: () -> Void) throws {
        try checkIssues()
        guard let stateTimeout else { throw CommandError("unsupported_xctest_runtime") }
        publishInputStarted()
        executionStarted = true // Before entering any API that can send input, including focus/select-all.
        observedReferences = RunnerAXReferences()
        let began = ProcessInfo.processInfo.systemUptime
        // Idle may exceed this short budget during normal deceleration. Avoid synchronous
        // timeout diagnostics; the caller still checks XCTest errors and frame stability.
        XCTestDiagnostics.withoutAutomaticSpindump { stateTimeout.perform(body) }
        print("IPHONE_USE_INPUT beganUptime=\(began) finishedUptime=\(ProcessInfo.processInfo.systemUptime)")
        try checkIssues() // Never continue a multi-primitive input after an XCTest failure.
    }
}
