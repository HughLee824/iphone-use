import ArgumentParser
import IPhoneUseCore
import Foundation

struct TypeText: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type", abstract: "Insert, replace, or append in a text input.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @Argument(
        help:
            """
            touch-paste uses current oN in either mode and only stages the clipboard. Other Runner methods use\
             a current oN:eN text input reference; multiline requires text_view. apple-native uses oN after\
             visual focus confirmation for every mode. Single-line ASCII uses HID (64 characters); Unicode or\
             multiline text temporarily uses the device clipboard and one HID Paste shortcut (4096 UTF-8 bytes).
            """
    ) var reference: String
    @Option(
        help:
            """
            insert uses the current caret/selection; replace selects all (XCTest also focuses the referenced\
             field); Runner append reads validated non-secure text and replaces it with the concatenated\
             result; native append requests document end. Native modes never focus implicitly.
            """
    ) var mode: String
    @Option(
        help:
            """
            Literal text up to 4096 UTF-8 bytes; Runner text_view accepts LF; native auto/paste accepts LF/CR,\
             other control keys are unsupported. Empty text clears in replace mode.
            """
    ) var text: String?
    @Option(
        help:
            """
            Both modes: touch-paste only stages literal text, without keyboard events; use oN and --mode\
             insert, then long-press/tap the visible Paste menu and text-finish after verification. Standard\
             only: auto uses keys for single-line ASCII and paste for Unicode or multiline text; keys sends up\
             to 64 US-mapped ASCII characters through the active layout; paste inserts literal text via the\
             device clipboard (up to 4096 UTF-8 bytes).
            """
    ) var method: String?
    @Option(
        help:
            """
            Native type oN only: complete input field x,y,width,height in screen points; single-frame field\
             comparison; use --caret-rect to confirm a visible caret exception and the default whole-screen\
             guard. Does not focus. Omit to protect the whole screen.
            """
    ) var fieldRect: String?
    @Option(
        help:
            """
            Native only: visually confirmed visible caret x,y,width,height in the referenced oN, inside\
             --field-rect. Width <=4, height 8...80 points. Excludes those fixed pixels from comparison for\
             this action; no color or opacity inference, never reused after editing.
            """
    ) var caretRect: String?
    @Option(
        help:
            """
            Native type/press with --field-rect only: exclude one video/animation rectangle x,y,width,height\
             outside the complete field, at most 25% of screen. This action only.
            """
    ) var ignoreRect: String?
    @Flag(help: "Read UTF-8 text from stdin until EOF, up to 4096 bytes. No trimming; use instead of --text.")
    var stdin = false

    mutating func validate() throws {
        guard (text != nil) != stdin else { throw ValidationError("Choose exactly one of --text or --stdin") }
    }

    mutating func run() throws {
        let session = try options.requiredSession()
        try outputAction(
            session: session, observe: observation.observe, agentOutput: observation.output.agentOutput
        ) {
            let value: String
            do { value = try stdin ? TextInput.read(from: .standardInput) : text! } catch {
                return [
                    "session": session, "ok": false, "outcome": "not_dispatched",
                    "error": [
                        "code": (error as? IPhoneUseError)?.code ?? "stdin_read_failed",
                        "message": String(describing: error)
                    ]
                ]
            }
            var fields: [String: Any] = ["reference": reference, "mode": mode, "text": value]
            if let fieldRect { fields["fieldRect"] = fieldRect }
            if let caretRect { fields["caretRect"] = caretRect }
            if let ignoreRect { fields["ignoreRect"] = ignoreRect }
            if let method { fields["textMethod"] = method }
            // Old hosts ignore unknown type fields. A distinct operation makes
            // explicit method selection fail closed instead of silently using keys.
            return try SessionClient.call(
                session: session,
                operation: caretRect != nil
                    ? "type-with-caret" : (method == nil ? "type" : "type-with-method"),
                fields: fields)
        }
    }
}

struct TextPrepare: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "text-prepare",
        abstract:
            """
            Prepare this native session's keyboard without input or clipboard access, then capture a new\
             screenshot. Inspect it before typing or Return.
            """
    )
    @OptionGroup var options: SessionOptions
    @OptionGroup var presentation: AgentOutputOptions
    @Option(
        help: """
            Complete native input field x,y,width,height in screen points; capture a new Apple PNG text\
             observation.
            """
    ) var fieldRect: String?
    @Option(help: "Video rectangle outside the complete field, at most 25% of screen; requires --field-rect.")
    var ignoreRect: String?
    mutating func run() throws {
        let session = try options.requiredSession()
        try output(agentOutput: presentation.agentOutput) {
            guard fieldRect != nil || ignoreRect == nil else {
                throw ValidationError("--ignore-rect requires --field-rect")
            }
            var fields: [String: Any] = [:]
            if let fieldRect { fields["fieldRect"] = fieldRect }
            if let ignoreRect { fields["ignoreRect"] = ignoreRect }
            // Old hosts must reject the scoped request, not silently skip stability checks.
            return try SessionClient.call(
                session: session, operation: fieldRect == nil ? "text-prepare" : "text-prepare-scoped",
                fields: fields)
        }
    }
}

struct TextFinish: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "text-finish",
        abstract:
            """
            After visually verifying clipboard input (touch-paste in either mode, or native paste) and\
             resolving any paste dialog, restore this transaction's clipboard backup without disconnecting.
            """
    )
    @OptionGroup var options: SessionOptions
    @OptionGroup var presentation: AgentOutputOptions
    @Argument(
        help:
            "Current screenshot oN captured after the text action; confirms that you have checked its result."
    )
    var reference: String
    @Option(
        help:
            """
            Pending result.pasteboard.transactionID returned by type, or status.touchPaste.transactionID for\
             touch-paste.
            """
    ) var transaction: String

    mutating func run() throws {
        let session = try options.requiredSession()
        try output(agentOutput: presentation.agentOutput) {
            try SessionClient.call(
                session: session, operation: "text-finish",
                fields: ["reference": reference, "transaction": transaction]
            )
        }
    }
}

struct Press: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Send an explicit key to the existing keyboard focus.")
    @OptionGroup var options: SessionOptions
    @OptionGroup var observation: ActionObservationOptions
    @Argument(
        help:
            """
            Current text input reference, or native screenshot oN after visually confirming focus. Does not\
             tap to focus; Return can submit, search, or insert a newline depending on the app.
            """
    ) var reference: String
    @Option(
        help: "Key: return, backspace, left, right, up, down, tab, shift-tab. Native oN also supports escape."
    )
    var key: String
    @Option(
        help:
            """
            Native press oN only: complete focused field x,y,width,height in screen points, with the same\
             protection as native type.
            """
    ) var fieldRect: String?
    @Option(
        help:
            """
            Native only: visually confirmed visible caret x,y,width,height in the referenced oN, inside\
             --field-rect. Width <=4, height 8...80 points. Excludes those fixed pixels from comparison for\
             this action; no color or opacity inference, never reused after editing.
            """
    ) var caretRect: String?
    @Option(
        help:
            """
            Native type/press with --field-rect only: exclude one video/animation rectangle x,y,width,height\
             outside the complete field, at most 25% of screen. This action only.
            """
    ) var ignoreRect: String?
    mutating func run() throws {
        let session = try options.requiredSession()
        var fields: [String: Any] = ["reference": reference, "key": key]
        if let fieldRect { fields["fieldRect"] = fieldRect }
        if let caretRect { fields["caretRect"] = caretRect }
        if let ignoreRect { fields["ignoreRect"] = ignoreRect }
        try outputAction(
            session: session, observe: observation.observe, agentOutput: observation.output.agentOutput
        ) {
            try SessionClient.call(
                session: session, operation: caretRect == nil ? "press" : "press-with-caret", fields: fields)
        }
    }
}
