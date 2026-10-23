import ArgumentParser
import IPhoneUseCore
import Foundation

struct SessionOptions: ParsableArguments {
    @Option(help: "Session identifier returned by connect.") var session: String?

    func requiredSession() throws -> String {
        guard let session else { throw ValidationError("--session is required") }
        return session
    }
}

@main
struct IPhoneUse: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iphone-use", abstract: "Eyes and hands for agents operating a real iPhone.",
        version: RunnerSetup.releaseVersion,
        subcommands: [
            Configuration.self, Setup.self, BuildRunner.self, Devices.self, Sessions.self, Connect.self,
            Status.self,
            Apps.self, Open.self, Terminate.self, Relaunch.self, Observe.self, Inspect.self, Tap.self,
            DoubleTap.self,
            Pinch.self, LongPress.self, Swipe.self, Home.self, TypeText.self, TextPrepare.self,
            TextFinish.self,
            Press.self, RecordStart.self, RecordStop.self, Preview.self, Disconnect.self, Host.self,
            AuthorizationMonitor.self
        ])
    @OptionGroup var options: SessionOptions
}

func output(compact: Bool = false, agentOutput: Bool = false, _ operation: () throws -> [String: Any]) throws {
    let response: [String: Any]
    do { response = try operation() } catch {
        response = [
            "ok": false,
            "error": [
                "code": (error as? IPhoneUseError)?.code ?? "command_failed",
                "message": String(describing: error)
            ]
        ]
    }
    if compact, response["ok"] as? Bool == true, let result = response["result"] as? [String: Any],
        let text = result["text"] as? String {
        print(text)
    } else {
        print(
            String(
                data: try jsonData(agentOutput ? AgentOutput.render(response) : response), encoding: .utf8)!)
    }
    if response["ok"] as? Bool != true { throw ExitCode.failure }
}

struct AgentOutputOptions: ParsableArguments {
    @Flag(
        help:
            """
            Return a concise diagnostic summary and a private temporary receipt path containing the full\
             response. Does not change execution or exit status.
            """
    ) var agentOutput = false
}

struct ActionObservationOptions: ParsableArguments {
    @OptionGroup var output: AgentOutputOptions
    @Flag(
        help:
            """
            Follow this action with a fresh observation. Return JSON with separate action and observation\
             results; never replay input.
            """
    ) var observe = false
}

func outputAction(session: String, observe: Bool, agentOutput: Bool, _ operation: () throws -> [String: Any])
    throws {
    try output(agentOutput: agentOutput) {
        let action = try operation()
        return observe ? SessionClient.observing(session: session, action: action) : action
    }
}
