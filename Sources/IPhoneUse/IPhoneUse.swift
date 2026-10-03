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
        commandName: "iphone-use", abstract: "Eyes and hands for agents operating a real iPhone.", version: RunnerSetup.releaseVersion,
        subcommands: [Configuration.self, Setup.self, BuildRunner.self, Devices.self, Connect.self, Status.self, Apps.self, Open.self, Terminate.self, Relaunch.self, Observe.self, Inspect.self, Tap.self, DoubleTap.self, Pinch.self, LongPress.self, Swipe.self, Home.self, TypeText.self, TextPrepare.self, TextFinish.self, Press.self, RecordStart.self, RecordStop.self, Disconnect.self, Host.self])
    @OptionGroup var options: SessionOptions
}

private func output(compact: Bool = false, agentOutput: Bool = false, _ operation: () throws -> [String: Any]) throws {
    let response: [String: Any]
    do { response = try operation() }
    catch {
        response = ["ok": false, "error": ["code": (error as? IPhoneUseError)?.code ?? "command_failed",
                                            "message": String(describing: error)]]
    }
    if compact, response["ok"] as? Bool == true, let result = response["result"] as? [String: Any],
       let text = result["text"] as? String { print(text) }
    else { print(String(decoding: try jsonData(agentOutput ? AgentOutput.render(response) : response), as: UTF8.self)) }
    if response["ok"] as? Bool != true { throw ExitCode.failure }
}

struct AgentOutputOptions: ParsableArguments {
    @Flag(help: "Return a concise diagnostic summary and a private temporary receipt path containing the full response. Does not change execution or exit status.") var agentOutput = false
}

struct ActionObservationOptions: ParsableArguments {
    @OptionGroup var output: AgentOutputOptions
    @Flag(help: "Follow this action with a fresh observation. Return JSON with separate action and observation results; never replay input.") var observe = false
}

private func outputAction(session: String, observe: Bool, agentOutput: Bool, _ operation: () throws -> [String: Any]) throws {
    try output(agentOutput: agentOutput) {
        let action = try operation()
        return observe ? SessionClient.observing(session: session, action: action) : action
    }
}

struct BuildRunner: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "build-runner", abstract: "Build and verify the signed Runner using Xcode; return its .xctestrun path.")
    @Option(help: "iPhone-use source checkout; defaults to the current directory.") var sourceRoot = "."
    @Option(help: "Apple development team ID; omit to use the Runner project's signing settings.") var team: String?
    @Option(help: "Runner test bundle ID; omit to use the Runner project's signing settings.") var bundleID: String?

    mutating func run() throws {
        try output {
            ["ok": true, "result": try RunnerBuild.build(sourceRoot: URL(fileURLWithPath: sourceRoot), team: team, bundleID: bundleID)]
        }
    }
}

struct Connect: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start a device session; standard needs no Runner setup or signing.",
        discussion: "Use devices to select a paired, unlocked iPhone with Developer Mode enabled. Both modes require full Xcode. Standard currently targets macOS/iOS 27. Check result.controlAvailable before standard-mode input; ok:true may describe an observation-only session. Use --mode runner explicitly for XCTest; modes never switch automatically.")
    @Option(help: "Connected iPhone UDID or CoreDevice identifier.") var device: String
    @Option(help: "Runner source workflow: explicit signed .xctestrun. Packaged Runner users run setup once, then omit this option.") var xctestrun: String?
    @Option(help: "Idle duration, such as 30m, 60m or 10s.") var idleTimeout = "30m"
    @Option(help: "standard (screenshot/HID, no Runner setup) or runner (XCTest). Omit to use saved preferences; fresh users default to standard.") var mode: String?
    @Option(help: "Compatibility option: apple-native = standard; xctest = runner. Conflicting options are rejected.") var backend: String?
    @Option(help: "Diagnostic override: a recent Apple netstat -anvl -p tcp file selects direct RSD discovery. Native connections normally use CoreDevice service sockets.") var nativeEndpointInventory: String?

    mutating func run() throws {
        try output {
            let timeout = try IdleTimeout(idleTimeout)
            let selection = try ModeConfiguration().select(mode: mode, backend: backend, xctestrun: xctestrun,
                                                           nativeEndpointInventory: nativeEndpointInventory)
            if selection.mode == .standard {
                return try SessionClient.connectNative(device: device, idleTimeout: timeout, endpointInventory: nativeEndpointInventory, modeSource: selection.source)
            }
            if let xctestrun {
                return try SessionClient.connect(device: device,
                    xctestrun: URL(fileURLWithPath: xctestrun).standardizedFileURL,
                    idleTimeout: timeout, modeSource: selection.source)
            }
            return try RunnerSetup.connect(device: device, idleTimeout: timeout, modeSource: selection.source)
        }
    }
}

struct Configuration: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config", abstract: "Read or set defaults in ~/.iphone-use/config.json (IPHONE_USE_CONFIG_DIR overrides the directory without legacy migration).",
                                                     subcommands: [Get.self, Set.self])
    struct Get: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Read the effective default mode without creating configuration or connecting a device.")
        @Argument(help: "Configuration key: mode.") var key: String
        mutating func run() throws {
            try output {
                guard key == "mode" else { throw ValidationError("Supported configuration key: mode") }
                return ["ok": true, "result": try ModeConfiguration().get()]
            }
        }
    }
    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Save the mode for future sessions; existing sessions keep their backend.")
        @Argument(help: "Configuration key: mode.") var key: String
        @Argument(help: "standard or runner.") var value: String
        mutating func run() throws {
            try output {
                guard key == "mode" else { throw ValidationError("Supported configuration key: mode") }
                return ["ok": true, "result": try ModeConfiguration().set(mode: value)]
            }
        }
    }
}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Runner mode only: re-sign and verify this release's precompiled Runner. Standard mode does not need setup. Does not change the default mode.")
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
    static let configuration = CommandConfiguration(abstract: "Check the selected session backend without renewing idle time.")
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
        try outputAction(session: session, observe: observation.observe, agentOutput: observation.output.agentOutput) { try SessionClient.call(session: session, operation: "open", fields: ["bundleId": bundleID]) }
    }
}

struct Terminate: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Terminate the specified app and confirm it has stopped. Unsaved app state may be lost.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @Argument(help: "Exact installed app bundle identifier returned by apps.") var bundleID: String
    mutating func run() throws {
        let session = try options.requiredSession()
        try outputAction(session: session, observe: observation.observe, agentOutput: observation.output.agentOutput) {
            try SessionClient.call(session: session, operation: "terminate", fields: ["bundleId": bundleID])
        }
    }
}

struct Relaunch: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Confirm the app has stopped, then launch it once. Inspect the screenshot for page readiness.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @Argument(help: "Exact installed app bundle identifier returned by apps. Unsaved app state may be lost.") var bundleID: String
    mutating func run() throws {
        let session = try options.requiredSession()
        try outputAction(session: session, observe: observation.observe, agentOutput: observation.output.agentOutput) {
            try SessionClient.call(session: session, operation: "relaunch", fields: ["bundleId": bundleID])
        }
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
    static let configuration = CommandConfiguration(abstract: "Capture a screenshot with a new observation ID; Runner also returns available elements.")
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
                throw IPhoneUseError("inspect_query_unsupported", "Session host did not confirm this query; disconnect and connect using the current CLI, then observe again")
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

    @Option(help: "Exclude one visually identified video/animation rectangle from the pre-input global comparison: x,y,width,height in screen points. Coordinate gestures only; at most 25% of screen; cannot overlap protected regions. Applies to this action only.") var ignoreRect: String?

    var fields: [String: Any] {
        var value: [String: Any] = ["maxScreenChange": maxScreenChange, "maxRegionChange": maxRegionChange, "protect": protect]
        value["ignoreRect"] = ignoreRect
        return value
    }
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
        try outputAction(session: session, observe: observation.observe, agentOutput: observation.output.agentOutput) { try SessionClient.call(session: session, operation: "tap", fields: fields) }
    }
}

struct DoubleTap: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "double-tap", abstract: "Double tap one screenshot point with backend-controlled timing.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @OptionGroup var screenGuard: ScreenGuardOptions
    @Argument(help: "Current screenshot observation ID.") var reference: String
    @Option(help: "Horizontal screen point coordinate.") var x: Double
    @Option(help: "Vertical screen point coordinate.") var y: Double
    mutating func run() throws {
        let session = try options.requiredSession()
        var fields = screenGuard.fields
        fields["reference"] = reference; fields["x"] = x; fields["y"] = y
        try outputAction(session: session, observe: observation.observe, agentOutput: observation.output.agentOutput) { try SessionClient.call(session: session, operation: "double-tap", fields: fields) }
    }
}

struct Pinch: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Move two fingers symmetrically along the screenshot X axis.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @OptionGroup var screenGuard: ScreenGuardOptions
    @Argument(help: "Current screenshot observation ID.") var reference: String
    @Option(help: "Center horizontal screen point coordinate.") var x: Double
    @Option(help: "Center vertical screen point coordinate.") var y: Double
    @Option(help: "Initial finger separation in screen points, at least 20.") var fromDistance: Double
    @Option(help: "Final separation in screen points; larger spreads, smaller pinches.") var toDistance: Double
    @Option(help: "Movement seconds, 0.1...5; default 0.5.") var duration: Double = 0.5
    mutating func run() throws {
        let session = try options.requiredSession()
        var fields = screenGuard.fields
        fields["reference"] = reference; fields["x"] = x; fields["y"] = y
        fields["fromDistance"] = fromDistance; fields["toDistance"] = toDistance; fields["duration"] = duration
        try outputAction(session: session, observe: observation.observe, agentOutput: observation.output.agentOutput) { try SessionClient.call(session: session, operation: "pinch", fields: fields) }
    }
}

struct LongPress: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "long-press", abstract: "Hold a screenshot point, then release.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @OptionGroup var screenGuard: ScreenGuardOptions
    @Argument(help: "Current screenshot observation ID.") var reference: String
    @Option(help: "Horizontal screen point coordinate.") var x: Double
    @Option(help: "Vertical screen point coordinate.") var y: Double
    @Option(help: "Hold duration in seconds, 0.5...5; default 0.8.") var duration: Double = 0.8
    mutating func run() throws {
        let session = try options.requiredSession()
        var fields = screenGuard.fields
        fields["reference"] = reference; fields["x"] = x; fields["y"] = y; fields["duration"] = duration
        try outputAction(session: session, observe: observation.observe, agentOutput: observation.output.agentOutput) { try SessionClient.call(session: session, operation: "long-press", fields: fields) }
    }
}

struct Home: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Press and release Home after checking a current screenshot.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @Argument(help: "Current screenshot observation ID.") var reference: String
    mutating func run() throws {
        let session = try options.requiredSession()
        try outputAction(session: session, observe: observation.observe, agentOutput: observation.output.agentOutput) {
            try SessionClient.call(session: session, operation: "home", fields: ["reference": reference])
        }
    }
}

struct Swipe: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Swipe or drag with explicit speed and holds after a screen guard.",
        discussion: """
        With --direction, the finger moves across 60% of the element's visible height or width; this can cross several wheel rows. Slower velocity does not shorten the distance.

        For wheel adjustments near the target, inspect the current value and row spacing, then use an observation ID with explicit endpoints. For example, if the observed rows are about 48 screen points apart:
          iphone-use --session SESSION swipe oN --from-x 228 --from-y 385 --to-x 228 --to-y 337 --velocity 100 --hold-duration 0.2
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
        try outputAction(session: session, observe: observation.observe, agentOutput: observation.output.agentOutput) { try SessionClient.call(session: session, operation: "swipe", fields: fields) }
    }
}

struct TypeText: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "type", abstract: "Insert, replace, or append in a text input.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @Argument(help: "Runner uses a current oN:eN text input reference; multiline requires text_view. apple-native uses oN after visual focus confirmation for every mode. Single-line ASCII uses HID (64 characters); Unicode or multiline text temporarily uses the device clipboard and one HID Paste shortcut (4096 UTF-8 bytes).") var reference: String
    @Option(help: "insert uses the current caret/selection; replace selects all (XCTest also focuses the referenced field); Runner append reads validated non-secure text and replaces it with the concatenated result; native append requests document end. Native modes never focus implicitly.") var mode: String
    @Option(help: "Literal text up to 4096 UTF-8 bytes; Runner text_view accepts LF; native auto/paste accepts LF/CR, other control keys are unsupported. Empty text clears in replace mode.") var text: String?
    @Option(help: "apple-native only: auto uses keys for single-line ASCII and paste for Unicode or multiline text; keys sends up to 64 US-mapped ASCII characters through the active layout; paste inserts literal text via the device clipboard (up to 4096 UTF-8 bytes).") var method: String?
    @Option(help: "Native type oN only: complete input field x,y,width,height in screen points; local field comparison with bounded automatic caret exclusion and the default whole-screen guard. Does not focus. Omit to protect the whole screen.") var fieldRect: String?
    @Option(help: "Native type/press with --field-rect only: exclude one video/animation rectangle x,y,width,height outside the complete field, at most 25% of screen. This action only.") var ignoreRect: String?
    @Flag(help: "Read UTF-8 text from stdin until EOF, up to 4096 bytes. No trimming; use instead of --text.") var stdin = false

    mutating func validate() throws {
        guard (text != nil) != stdin else { throw ValidationError("Choose exactly one of --text or --stdin") }
    }

    mutating func run() throws {
        let session = try options.requiredSession()
        try outputAction(session: session, observe: observation.observe, agentOutput: observation.output.agentOutput) {
            let value: String
            do { value = try stdin ? TextInput.read(from: .standardInput) : text! }
            catch {
                return ["session": session, "ok": false, "outcome": "not_dispatched",
                        "error": ["code": (error as? IPhoneUseError)?.code ?? "stdin_read_failed", "message": String(describing: error)]]
            }
            var fields: [String: Any] = ["reference": reference, "mode": mode, "text": value]
            if let fieldRect { fields["fieldRect"] = fieldRect }
            if let ignoreRect { fields["ignoreRect"] = ignoreRect }
            if let method { fields["textMethod"] = method }
            // Old hosts ignore unknown type fields. A distinct operation makes
            // explicit method selection fail closed instead of silently using keys.
            return try SessionClient.call(session: session, operation: method == nil ? "type" : "type-with-method", fields: fields)
        }
    }
}

struct TextPrepare: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "text-prepare", abstract: "Prepare this native session's keyboard without input or clipboard access, then capture a new screenshot. Inspect it before typing or Return.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var presentation: AgentOutputOptions
    @Option(help: "Complete native input field x,y,width,height in screen points; establish a stable new text observation.") var fieldRect: String?
    @Option(help: "Video rectangle outside the complete field, at most 25% of screen; requires --field-rect.") var ignoreRect: String?
    mutating func run() throws {
        let session = try options.requiredSession()
        try output(agentOutput: presentation.agentOutput) {
            guard fieldRect != nil || ignoreRect == nil else { throw ValidationError("--ignore-rect requires --field-rect") }
            var fields: [String: Any] = [:]
            if let fieldRect { fields["fieldRect"] = fieldRect }
            if let ignoreRect { fields["ignoreRect"] = ignoreRect }
            // Old hosts must reject the scoped request, not silently skip stability checks.
            return try SessionClient.call(session: session, operation: fieldRect == nil ? "text-prepare" : "text-prepare-scoped", fields: fields)
        }
    }
}

struct TextFinish: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "text-finish", abstract: "After visually verifying native text input and resolving any paste dialog, restore this transaction's clipboard backup without disconnecting.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var presentation: AgentOutputOptions
    @Argument(help: "Current screenshot oN captured after the text action; confirms that you have checked its result.") var reference: String
    @Option(help: "Pending result.pasteboard.transactionID returned by native type or status.") var transaction: String

    mutating func run() throws {
        let session = try options.requiredSession()
        try output(agentOutput: presentation.agentOutput) { try SessionClient.call(session: session, operation: "text-finish", fields: ["reference": reference, "transaction": transaction]) }
    }
}

struct Press: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Send an explicit key to the existing keyboard focus.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @Argument(help: "Current text input reference, or native screenshot oN after visually confirming focus. Does not tap to focus; Return can submit, search, or insert a newline depending on the app.") var reference: String
    @Option(help: "Key: return, backspace, left, right, up, down, tab, shift-tab. Native oN also supports escape.") var key: String
    @Option(help: "Native press oN only: complete focused field x,y,width,height in screen points, with the same protection as native type.") var fieldRect: String?
    @Option(help: "Native type/press with --field-rect only: exclude one video/animation rectangle x,y,width,height outside the complete field, at most 25% of screen. This action only.") var ignoreRect: String?
    mutating func run() throws {
        let session = try options.requiredSession()
        var fields: [String: Any] = ["reference": reference, "key": key]
        if let fieldRect { fields["fieldRect"] = fieldRect }
        if let ignoreRect { fields["ignoreRect"] = ignoreRect }
        try outputAction(session: session, observe: observation.observe, agentOutput: observation.output.agentOutput) { try SessionClient.call(session: session, operation: "press", fields: fields) }
    }
}


struct RecordStart: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "record-start", abstract: "Start an owned native media recording in either control mode; status reports its MP4.")
    @OptionGroup var options: SessionOptions
    @Option(help: "Automatic stop after 1–300 seconds (default 60); record-stop may end it earlier.") var duration: Double = 60
    mutating func run() throws {
        let session = try options.requiredSession()
        try output { try SessionClient.call(session: session, operation: "record-start", fields: ["duration": duration]) }
    }
}

struct RecordStop: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "record-stop", abstract: "Stop only the specified recording, save and validate its MP4; never replay a start.")
    @OptionGroup var options: SessionOptions
    @Argument(help: "Recording ID returned by record-start or status.") var recordingID: String
    mutating func run() throws {
        let session = try options.requiredSession()
        try output { try SessionClient.call(session: session, operation: "record-stop", fields: ["recordingID": recordingID]) }
    }
}
