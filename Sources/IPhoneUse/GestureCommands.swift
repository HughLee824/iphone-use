import ArgumentParser
import IPhoneUseCore
import Foundation

struct ScreenGuardOptions: ParsableArguments {
    @Option(
        help:
            """
            Maximum screen-grid change BEFORE input, relative to the observation (0...1); default 0.01. Not\
             the expected scroll or animation size.
            """
    ) var maxScreenChange = 0.01
    @Option(help: "Maximum changed protected-region fraction (0...max-screen-change); default 0.")
    var maxRegionChange =
        0.0
    @Option(
        help:
            "Additional element reference to protect, repeat up to three times; same observation as the action."
    )
    var protect: [String] = []

    @Option(
        help:
            """
            Exclude one visually identified video/animation rectangle from the pre-input global comparison: x\
            ,y,width,height in screen points. Coordinate gestures only; at most 25% of screen; cannot overlap\
             protected regions. Applies to this action only.
            """
    ) var ignoreRect: String?

    @Option(
        help:
            """
            Tap only: tightly bound a visible overlay control, x,y,width,height (up to 96x96 points). Requires\
             --dynamic-anchor; retains exact geometry and local-contrast shape validation while video changes.
            """
    ) var dynamicTarget: String?
    @Option(
        help:
            """
            Independent visible page label/control for a dynamic tap, x,y,width,height (up to 256x96 points).\
             Must not overlap the target. No whole-screen bypass.
            """
    ) var dynamicAnchor: String?

    var fields: [String: Any] {
        var value: [String: Any] = [
            "maxScreenChange": maxScreenChange, "maxRegionChange": maxRegionChange, "protect": protect
        ]
        value["ignoreRect"] = ignoreRect
        value["dynamicTarget"] = dynamicTarget; value["dynamicAnchor"] = dynamicAnchor
        return value
    }
}

struct Tap: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Tap a current element, or a point in a current observation.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @OptionGroup var screenGuard: ScreenGuardOptions
    @Argument(help: "Element reference; use an observation ID with --x and --y.") var reference: String
    @Option(name: .customLong("x"), help: "Horizontal screen point coordinate.") var column: Double?
    @Option(name: .customLong("y"), help: "Vertical screen point coordinate.") var row: Double?
    mutating func run() throws {
        let session = try options.requiredSession()
        var fields = screenGuard.fields
        fields["reference"] = reference
        fields["x"] = column; fields["y"] = row
        try outputAction(
            session: session, observe: observation.observe, agentOutput: observation.output.agentOutput
        ) {
            try SessionClient.call(session: session, operation: "tap", fields: fields)
        }
    }
}

struct DoubleTap: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "double-tap", abstract: "Double tap one screenshot point with backend-controlled timing."
    )
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @OptionGroup var screenGuard: ScreenGuardOptions
    @Argument(help: "Current screenshot observation ID.") var reference: String
    @Option(name: .customLong("x"), help: "Horizontal screen point coordinate.") var column: Double
    @Option(name: .customLong("y"), help: "Vertical screen point coordinate.") var row: Double
    mutating func run() throws {
        let session = try options.requiredSession()
        var fields = screenGuard.fields
        fields["reference"] = reference; fields["x"] = column; fields["y"] = row
        try outputAction(
            session: session, observe: observation.observe, agentOutput: observation.output.agentOutput
        ) {
            try SessionClient.call(session: session, operation: "double-tap", fields: fields)
        }
    }
}

struct Pinch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Move two fingers symmetrically along the screenshot X axis.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @OptionGroup var screenGuard: ScreenGuardOptions
    @Argument(help: "Current screenshot observation ID.") var reference: String
    @Option(name: .customLong("x"), help: "Center horizontal screen point coordinate.") var column: Double
    @Option(name: .customLong("y"), help: "Center vertical screen point coordinate.") var row: Double
    @Option(help: "Initial finger separation in screen points, at least 20.") var fromDistance: Double
    @Option(help: "Final separation in screen points; larger spreads, smaller pinches.") var toDistance: Double
    @Option(help: "Movement seconds, 0.1...5; default 0.5.") var duration: Double = 0.5
    mutating func run() throws {
        let session = try options.requiredSession()
        var fields = screenGuard.fields
        fields["reference"] = reference; fields["x"] = column; fields["y"] = row
        fields["fromDistance"] = fromDistance; fields["toDistance"] = toDistance
        fields["duration"] = duration
        try outputAction(
            session: session, observe: observation.observe, agentOutput: observation.output.agentOutput
        ) {
            try SessionClient.call(session: session, operation: "pinch", fields: fields)
        }
    }
}

struct LongPress: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "long-press", abstract: "Hold a screenshot point, then release.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @OptionGroup var screenGuard: ScreenGuardOptions
    @Argument(help: "Current screenshot observation ID.") var reference: String
    @Option(name: .customLong("x"), help: "Horizontal screen point coordinate.") var column: Double
    @Option(name: .customLong("y"), help: "Vertical screen point coordinate.") var row: Double
    @Option(help: "Hold duration in seconds, 0.5...5; default 0.8.") var duration: Double = 0.8
    mutating func run() throws {
        let session = try options.requiredSession()
        var fields = screenGuard.fields
        fields["reference"] = reference; fields["x"] = column; fields["y"] = row
        fields["duration"] = duration
        try outputAction(
            session: session, observe: observation.observe, agentOutput: observation.output.agentOutput
        ) {
            try SessionClient.call(session: session, operation: "long-press", fields: fields)
        }
    }
}

struct Home: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Press and release Home after checking a current screenshot.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @Argument(help: "Current screenshot observation ID.") var reference: String
    mutating func run() throws {
        let session = try options.requiredSession()
        try outputAction(
            session: session, observe: observation.observe, agentOutput: observation.output.agentOutput
        ) {
            try SessionClient.call(session: session, operation: "home", fields: ["reference": reference])
        }
    }
}

struct Swipe: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Swipe or drag with explicit speed and holds after a screen guard.",
        discussion: """
            With --direction, the finger moves across 60% of the element's visible height or width; this can\
             cross several wheel rows. Slower velocity does not shorten the distance.

            For wheel adjustments near the target, inspect the current value and row spacing, then use an\
             observation ID with explicit endpoints. For example, if the observed rows are about 48 screen\
             points apart:
              iphone-use --session SESSION swipe oN --from-x 228 --from-y 385 --to-x 228 --to-y 337 --velocity\
             100 --hold-duration 0.2
            Replace the session, observation, and coordinates with current observed values. Optionally add\
             --protect oN:eN; do not combine an element reference as the target with endpoints.

            The speed and hold values are starting points, not a one-row guarantee. After every dispatched\
             action, including no change, observe and verify the actual selected value. Repeated no-change or\
             overshoot calls for checking the field and geometry before another attempt. completed means input\
             finished and the screen stabilized.

            For drag-and-drop, add --press-duration (for example 0.5). Estimated motion is limited to 10\
             seconds. Keep screen-guard defaults unless a concrete pre-input screen change warrants a\
             different policy.
            """)
    @OptionGroup var options: SessionOptions
    @OptionGroup var screenGuard: ScreenGuardOptions
    @OptionGroup var observation: ActionObservationOptions
    @Argument(help: "Element reference with --direction; observation ID with explicit endpoints.")
    var reference: String
    @Option(help: "Finger movement across 60% of the visible element: up, down, left or right.")
    var direction: String?
    @Option(help: "Start horizontal screen point coordinate.") var fromX: Double?
    @Option(help: "Start vertical screen point coordinate.") var fromY: Double?
    @Option(help: "End horizontal screen point coordinate.") var toX: Double?
    @Option(help: "End vertical screen point coordinate.") var toY: Double?
    @Option(
        help:
            """
            Speed in XCTest pixels/second, or original screenshot pixels/second for apple-native; 0 < value <=\
             10000, default 500.
            """
    ) var velocity: Double?
    @Option(help: "Seconds to hold at the start BEFORE moving, not drag duration; 0...5, default 0.")
    var pressDuration: Double?
    @Option(help: "Seconds to hold at the end BEFORE lifting; 0...5, default 0.") var holdDuration: Double?
    mutating func run() throws {
        let session = try options.requiredSession()
        var fields = screenGuard.fields
        fields["reference"] = reference; fields["direction"] = direction
        fields["fromX"] = fromX; fields["fromY"] = fromY; fields["toX"] = toX; fields["toY"] = toY
        fields["velocity"] = velocity; fields["pressDuration"] = pressDuration
        fields["holdDuration"] = holdDuration
        try outputAction(
            session: session, observe: observation.observe, agentOutput: observation.output.agentOutput
        ) {
            try SessionClient.call(session: session, operation: "swipe", fields: fields)
        }
    }
}
