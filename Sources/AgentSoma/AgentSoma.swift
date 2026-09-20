import ArgumentParser
import AgentSomaCore
import Foundation

struct SessionOptions: ParsableArguments {
    @Option(help: "Session identifier returned by connect.") var session: String?

    func requiredSession() throws -> String {
        guard let session else { throw ValidationError("--session is required") }
        return session
    }
}

@main
struct AgentSoma: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agentsoma", abstract: "Eyes and hands for agents operating a real iPhone.", version: RunnerSetup.releaseVersion,
        subcommands: [Setup.self, BuildRunner.self, Devices.self, Connect.self, Status.self, Apps.self, Open.self, Observe.self, Inspect.self, Tap.self, Swipe.self, TypeText.self, TextFinish.self, Press.self, Disconnect.self, Host.self])
    @OptionGroup var options: SessionOptions
}

private func output(compact: Bool = false, _ operation: () throws -> [String: Any]) throws {
    let response: [String: Any]
    do { response = try operation() }
    catch {
        response = ["ok": false, "error": ["code": (error as? SomaError)?.code ?? "command_failed",
                                            "message": String(describing: error)]]
    }
    if compact, response["ok"] as? Bool == true, let result = response["result"] as? [String: Any],
       let text = result["text"] as? String { print(text) }
    else { print(String(decoding: try jsonData(response), as: UTF8.self)) }
    if response["ok"] as? Bool != true { throw ExitCode.failure }
}

struct ActionObservationOptions: ParsableArguments {
    @Flag(help: "Follow this action with a fresh observation. Return JSON with separate action and observation results; never replay input.") var observe = false
}

private func outputAction(session: String, observe: Bool, _ operation: () throws -> [String: Any]) throws {
    try output {
        let action = try operation()
        return observe ? SessionClient.observing(session: session, action: action) : action
    }
}

struct BuildRunner: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "build-runner", abstract: "Build and verify the signed Runner using Xcode; return its .xctestrun path.")
    @Option(help: "AgentSoma source checkout; defaults to the current directory.") var sourceRoot = "."
    @Option(help: "Apple development team ID; omit to use the Runner project's signing settings.") var team: String?
    @Option(help: "Runner test bundle ID; omit to use the Runner project's signing settings.") var bundleID: String?

    mutating func run() throws {
        try output {
            ["ok": true, "result": try RunnerBuild.build(sourceRoot: URL(fileURLWithPath: sourceRoot), team: team, bundleID: bundleID)]
        }
    }
}

struct Connect: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start a device session using the selected backend.")
    @Option(help: "Connected iPhone UDID or CoreDevice identifier.") var device: String
    @Option(help: "Developer override: explicit signed .xctestrun. Release users run setup once, then omit this option.") var xctestrun: String?
    @Option(help: "Idle duration, such as 30m, 60m or 10s.") var idleTimeout = "30m"
    @Option(help: "xctest (default) or experimental apple-native. Native readiness reports control availability explicitly.") var backend = "xctest"
    @Option(help: "Diagnostic override: a recent Apple netstat -anvl -p tcp file selects direct RSD discovery. Native connections normally use CoreDevice service sockets.") var nativeEndpointInventory: String?

    mutating func run() throws {
        try output {
            guard ["xctest", "apple-native"].contains(backend) else { throw ValidationError("Use --backend xctest or apple-native") }
            if backend == "apple-native" {
                guard xctestrun == nil else { throw ValidationError("--xctestrun is not used by apple-native") }
                return try SessionClient.connectNative(device: device, idleTimeout: IdleTimeout(idleTimeout), endpointInventory: nativeEndpointInventory)
            }
            guard nativeEndpointInventory == nil else { throw ValidationError("--native-endpoint-inventory requires --backend apple-native") }
            if let xctestrun {
                return try SessionClient.connect(device: device,
                    xctestrun: URL(fileURLWithPath: xctestrun).standardizedFileURL,
                    idleTimeout: IdleTimeout(idleTimeout))
            }
            return try RunnerSetup.connect(device: device, idleTimeout: IdleTimeout(idleTimeout))
        }
    }
}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Re-sign and deploy this release's precompiled Runner; verify connection and capture. No source compilation.")
    @Option(help: "Connected iPhone UDID or CoreDevice identifier.") var device: String
    @Option(help: "iOS development .mobileprovision file; otherwise use saved or matching Xcode profiles.") var profile: String?
    @Option(help: "Apple Development signing certificate SHA-1; required only when selection is ambiguous.") var identity: String?
    @Option(help: "Apple development team ID to select.") var team: String?
    @Option(help: "Runner app's bundle ID on iPhone; saved for subsequent setup and connections.") var bundleID: String?

    mutating func run() throws {
        try output { ["ok": true, "result": try RunnerSetup.setup(device: device, profile: profile, identity: identity, team: team, bundleID: bundleID)] }
    }
}

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List devices known to CoreDevice; connect checks session readiness.")
    mutating func run() throws {
        try output { ["ok": true, "result": ["devices": try DeviceDiscovery.devices()]] }
    }
}

struct Apps: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List installed apps, up to 50 per page, without changing the device UI.")
    @OptionGroup var options: SessionOptions
    @Option(help: "Case-insensitive substring of the app name or bundle ID.") var query: String?
    @Option(help: "Offset returned as nextOffset by the previous page.") var offset = 0
    mutating func run() throws {
        let session = try options.requiredSession()
        var fields: [String: Any] = ["offset": offset]
        fields["query"] = query
        try output { try SessionClient.call(session: session, operation: "apps", fields: fields) }
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check the session and Runner without renewing idle time.")
    @OptionGroup var options: SessionOptions
    mutating func run() throws {
        let session = try options.requiredSession()
        try output { try SessionClient.call(session: session, operation: "status") }
    }
}

struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Bring an app to the foreground and renew the session.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @Argument(help: "Installed app bundle identifier returned by apps.") var bundleID: String
    mutating func run() throws {
        let session = try options.requiredSession()
        try outputAction(session: session, observe: observation.observe) { try SessionClient.call(session: session, operation: "open", fields: ["bundleId": bundleID]) }
    }
}

struct Disconnect: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Finish admitted commands and release the session.")
    @OptionGroup var options: SessionOptions
    mutating func run() throws {
        let session = try options.requiredSession()
        try output { try SessionClient.call(session: session, operation: "disconnect") }
    }
}

struct Observe: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Capture a screenshot and compact AX text with new element references.")
    @OptionGroup var options: SessionOptions
    mutating func run() throws {
        let session = try options.requiredSession()
        try output(compact: true) { try SessionClient.call(session: session, operation: "observe") }
    }
}

struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Read or search a cached observation or subtree without recapturing or renewing references.",
        discussion: "Use --query to search all captured nodes before pagination, including nodes omitted from observe's text. "
            + "Matches include references, frames in screen points and parent references. Search does not prove visibility or clickability. "
            + "A truncated source may omit the target; inspect cannot fetch missing source data. "
            + "For an already known element, inspect its reference directly instead of paging the whole tree.")
    @OptionGroup var options: SessionOptions
    @Argument(help: "Observation or element reference, such as o1 or o1:e2.") var reference: String
    @Option(help: "Case-insensitive substring of label, identifier, value or role; 1–256 UTF-8 bytes, no control characters or blank-only text.") var query: String?
    @Option(help: "Node offset, or match offset with --query, returned by the previous inspect page.") var offset = 0
    mutating func run() throws {
        let session = try options.requiredSession()
        var fields: [String: Any] = ["reference": reference, "offset": offset]
        fields["query"] = query
        try output(compact: true) {
            let response = try SessionClient.call(session: session, operation: "inspect", fields: fields)
            if let query, response["ok"] as? Bool == true,
               (response["result"] as? [String: Any])?["query"] as? String != query {
                throw SomaError("inspect_query_unsupported", "Session host did not confirm this query; disconnect and connect using the current CLI, then observe again")
            }
            return response
        }
    }
}

struct Host: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_host", shouldDisplay: false)
    @Option var directory: String
    mutating func run() throws { try runHost(directory: URL(fileURLWithPath: directory, isDirectory: true)) }
}

struct ScreenGuardOptions: ParsableArguments {
    @Option(help: "Maximum screen-grid change BEFORE input, relative to the observation (0...1); default 0.01. Not the expected scroll or animation size.") var maxScreenChange = 0.01
    @Option(help: "Maximum changed protected-region fraction (0...max-screen-change); default 0.") var maxRegionChange = 0.0
    @Option(help: "Additional element reference to protect, repeat up to three times; same observation as the action.") var protect: [String] = []

    var fields: [String: Any] { ["maxScreenChange": maxScreenChange, "maxRegionChange": maxRegionChange, "protect": protect] }
}

struct Tap: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Tap a current element, or a point in a current observation.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @OptionGroup var screenGuard: ScreenGuardOptions
    @Argument(help: "Element reference; use an observation ID with --x and --y.") var reference: String
    @Option(help: "Horizontal screen point coordinate.") var x: Double?
    @Option(help: "Vertical screen point coordinate.") var y: Double?
    mutating func run() throws {
        let session = try options.requiredSession()
        var fields = screenGuard.fields
        fields["reference"] = reference
        fields["x"] = x; fields["y"] = y
        try outputAction(session: session, observe: observation.observe) { try SessionClient.call(session: session, operation: "tap", fields: fields) }
    }
}

struct Swipe: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Swipe or drag with explicit speed and holds after a screen guard.",
        discussion: """
        With --direction, the finger moves across 60% of the element's visible height or width; this can cross several wheel rows. Slower velocity does not shorten the distance.

        For wheel adjustments near the target, inspect the current value and row spacing, then use an observation ID with explicit endpoints. For example, if the observed rows are about 48 screen points apart:
          agentsoma --session SESSION swipe oN --from-x 228 --from-y 385 --to-x 228 --to-y 337 --velocity 100 --hold-duration 0.2
        Replace the session, observation, and coordinates with current observed values. Optionally add --protect oN:eN; do not combine an element reference as the target with endpoints.

        The speed and hold values are starting points, not a one-row guarantee. After every dispatched action, including no change, observe and verify the actual selected value. Repeated no-change or overshoot calls for checking the field and geometry before another attempt. completed means input finished and the screen stabilized.

        For drag-and-drop, add --press-duration (for example 0.5). Estimated motion is limited to 10 seconds. Keep screen-guard defaults unless a concrete pre-input screen change warrants a different policy.
        """)
    @OptionGroup var options: SessionOptions
    @OptionGroup var screenGuard: ScreenGuardOptions
    @OptionGroup var observation: ActionObservationOptions
    @Argument(help: "Element reference with --direction; observation ID with explicit endpoints.") var reference: String
    @Option(help: "Finger movement across 60% of the visible element: up, down, left or right.") var direction: String?
    @Option(help: "Start horizontal screen point coordinate.") var fromX: Double?
    @Option(help: "Start vertical screen point coordinate.") var fromY: Double?
    @Option(help: "End horizontal screen point coordinate.") var toX: Double?
    @Option(help: "End vertical screen point coordinate.") var toY: Double?
    @Option(help: "Speed in XCTest pixels/second, or original screenshot pixels/second for apple-native; 0 < value <= 10000, default 500.") var velocity: Double?
    @Option(help: "Seconds to hold at the start BEFORE moving, not drag duration; 0...5, default 0.") var pressDuration: Double?
    @Option(help: "Seconds to hold at the end BEFORE lifting; 0...5, default 0.") var holdDuration: Double?
    mutating func run() throws {
        let session = try options.requiredSession()
        var fields = screenGuard.fields
        fields["reference"] = reference; fields["direction"] = direction
        fields["fromX"] = fromX; fields["fromY"] = fromY; fields["toX"] = toX; fields["toY"] = toY
        fields["velocity"] = velocity; fields["pressDuration"] = pressDuration; fields["holdDuration"] = holdDuration
        try outputAction(session: session, observe: observation.observe) { try SessionClient.call(session: session, operation: "swipe", fields: fields) }
    }
}

struct TypeText: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "type", abstract: "Insert at the existing caret, or replace a text input's entire contents.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @Argument(help: "Current text input reference; apple-native uses oN after visual focus confirmation (insert only). ASCII uses HID (64 characters); Unicode temporarily uses the device clipboard and one HID Paste shortcut (4096 UTF-8 bytes).") var reference: String
    @Option(help: "insert requires existing keyboard focus; replace focuses and selects all.") var mode: String
    @Option(help: "Literal text up to 4096 UTF-8 bytes; no control keys or newlines. Empty text clears in replace mode.") var text: String?
    @Option(help: "apple-native only: auto preserves ASCII keys/Unicode paste; keys sends up to 64 US-mapped ASCII characters through the active layout; paste inserts literal text via the device clipboard (up to 4096 UTF-8 bytes).") var method: String?
    @Option(help: "Native type oN only: visually selected input field x,y,width,height in screen points; strict region guard plus default whole-screen guard. Does not focus. Omit to protect the whole screen strictly.") var fieldRect: String?
    @Flag(help: "Read UTF-8 text from stdin until EOF, up to 4096 bytes. No trimming; use instead of --text.") var stdin = false

    mutating func validate() throws {
        guard (text != nil) != stdin else { throw ValidationError("Choose exactly one of --text or --stdin") }
    }

    mutating func run() throws {
        let session = try options.requiredSession()
        try outputAction(session: session, observe: observation.observe) {
            let value: String
            do { value = try stdin ? TextInput.read(from: .standardInput) : text! }
            catch {
                return ["session": session, "ok": false, "outcome": "not_dispatched",
                        "error": ["code": (error as? SomaError)?.code ?? "stdin_read_failed", "message": String(describing: error)]]
            }
            var fields: [String: Any] = ["reference": reference, "mode": mode, "text": value]
            if let fieldRect { fields["fieldRect"] = fieldRect }
            if let method { fields["textMethod"] = method }
            // Old hosts ignore unknown type fields. A distinct operation makes
            // explicit method selection fail closed instead of silently using keys.
            return try SessionClient.call(session: session, operation: method == nil ? "type" : "type-with-method", fields: fields)
        }
    }
}

struct TextFinish: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "text-finish", abstract: "After visually verifying native text input and resolving any paste dialog, restore this transaction's clipboard backup without disconnecting.")
    @OptionGroup var options: SessionOptions
    @Argument(help: "Current screenshot oN captured after the text action; confirms that you have checked its result.") var reference: String
    @Option(help: "Pending result.pasteboard.transactionID returned by native type or status.") var transaction: String

    mutating func run() throws {
        let session = try options.requiredSession()
        try output { try SessionClient.call(session: session, operation: "text-finish", fields: ["reference": reference, "transaction": transaction]) }
    }
}

struct Press: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Send an explicit Return to a text input with existing keyboard focus.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @Argument(help: "Current text input reference; this command does not tap to focus.") var reference: String
    @Option(help: "Key to send; currently only return is supported.") var key: String
    mutating func run() throws {
        let session = try options.requiredSession()
        try outputAction(session: session, observe: observation.observe) { try SessionClient.call(session: session, operation: "press", fields: ["reference": reference, "key": key]) }
    }
}
