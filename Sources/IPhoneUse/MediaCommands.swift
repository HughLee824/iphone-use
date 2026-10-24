import ArgumentParser
import IPhoneUseCore
import Foundation

struct RecordStart: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record-start",
        abstract: "Start an owned native media recording in either control mode; status reports its MP4.")
    @OptionGroup var options: SessionOptions
    @Option(help: "Automatic stop after 1–300 seconds (default 60); record-stop may end it earlier.")
    var duration: Double = 60
    mutating func run() throws {
        let session = try options.requiredSession()
        try output {
            try SessionClient.call(
                session: session, operation: "record-start", fields: ["duration": duration])
        }
    }
}

struct RecordStop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record-stop",
        abstract: "Stop only the specified recording, save and validate its MP4; never replay a start.")
    @OptionGroup var options: SessionOptions
    @Argument(help: "Recording ID returned by record-start or status.") var recordingID: String
    mutating func run() throws {
        let session = try options.requiredSession()
        try output {
            try SessionClient.call(
                session: session, operation: "record-stop", fields: ["recordingID": recordingID])
        }
    }
}

struct Preview: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract:
            "Open an experimental, read-only local browser preview using the session's owned video stream.")
    @OptionGroup var options: SessionOptions
    @Flag(help: "Stop preview without stopping control or an active recording.") var stop = false
    @Flag(help: "Return the URL without opening a browser.") var noOpen = false
    @Option(
        help:
            """
            Loopback TCP port for this start (1024...65535). Overrides config preview-port; default 8765. An\
             occupied port returns preview_port_in_use; retry with another port.
            """
    ) var port: Int?
    mutating func run() throws {
        let session = try options.requiredSession()
        try output {
            guard !stop || port == nil else { throw ValidationError("--port cannot be combined with --stop") }
            let fields = stop ? [:] : try PreviewConfiguration().startFields(port: port)
            let response = try SessionClient.call(
                session: session, operation: stop ? "preview-stop" : "preview-start", fields: fields)
            if !stop, !noOpen, response["ok"] as? Bool == true,
                let result = response["result"] as? [String: Any], let url = result["url"] as? String {
                let open = Process(); open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                open.arguments = [url]
                try open.run(); open.waitUntilExit()
            }
            return response
        }
    }
}

struct PreviewServiceHost: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_preview-service", shouldDisplay: false)
    @Option var directory: String
    @Option var port: Int
    mutating func run() throws { try runPreviewService(directory: URL(fileURLWithPath: directory), port: port) }
}

struct PreviewRevoke: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preview-revoke",
        abstract: "Revoke a device preview URL. Explicitly stop/start preview to obtain a new URL.")
    @Option(help: "Exact hardware UDID of the device whose preview URL should be revoked.") var device: String
    @Option(help: "Preview service port; defaults to config preview-port.") var port: Int?
    mutating func run() throws { try output { try revokePreview(device: device, port: port) } }
}
