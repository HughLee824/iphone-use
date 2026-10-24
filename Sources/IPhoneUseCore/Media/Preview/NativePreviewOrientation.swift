import Foundation
import CoreImage

// Only read-only preview probes may defer a timeout. Never use this policy for
// input validation, stream startup, or a refresh that has already stopped media.
enum NativePreviewPoll {
    static func canDefer(_ error: Error, health: [String: Any]) -> Bool {
        guard let code = (error as? IPhoneUseError)?.code,
            ["coredevice_timeout", "coredevice_initialization_timeout"].contains(code),
            health["healthy"] as? Bool == true
        else { return false }
        let snapshots = health["snapshots"] as? [String: Any] ?? [:]
        return snapshots["closed"] as? Bool != true && snapshots["waitingForKeyframe"] as? Bool != true
    }
}

// A quiet screen can legitimately retain its last frame. Only a decoder that
// previously produced pictures and then lost its dependency chain needs recovery.
final class NativePreviewContinuity {
    private var lostSince: Double?

    func needsRecovery(_ status: [String: Any], now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard status["closed"] as? Bool == false,
            status["decodedFrames"] as? Int ?? 0 > 0,
            status["waitingForKeyframe"] as? Bool == true
        else {
            lostSince = nil
            return false
        }
        if lostSince == nil { lostSince = now }
        return now - lostSince! >= 3
    }
}

// Negative orientation evidence only. Never supplies observation pixels or an
// input coordinate transform. A conflict triggers an owned stop/read/rebind,
// after which CoreDevice supplies the authoritative orientation again.
final class NativePreviewOrientation {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var halfTurnConflicts = 0

    func needsRefresh(cli: AppleDeviceCLI, snapshots: NativeVideoSnapshot?, display: NativeDisplay) throws
        -> Bool {
        if let rotation = snapshots?.previewFrame(includeReducedResolution: true)?.displayRotation {
            // A recognized complete-frame tag makes the expensive same-source
            // PNG comparison redundant. Agreement is not capture freshness.
            halfTurnConflicts = 0
            return rotation != display.rotation
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "iphone-use-preview-direction-\(UUID().uuidString)")
        try SessionPaths.secureDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("screen.png")
        _ = try cli.read(["device", "capture", "screenshot", "--destination", destination.path], timeout: 3)
        let image = try ScreenImage(png: Data(contentsOf: destination))
        if image.image.width != Int(display.pixelWidth) || image.image.height != Int(display.pixelHeight) {
            halfTurnConflicts = 0
            return true
        }
        guard let frame = snapshots?.previewFrame(includeReducedResolution: true) else {
            halfTurnConflicts = 0; return false
        }
        let jpeg = try NativePreview.encode(frame, display: display, context: context)
        let decoded = try ScreenImage(png: jpeg)
        func grid(_ image: ScreenImage) throws -> Data {
            let rect = ScreenRect(CGRect(x: 0, y: 0, width: image.image.width, height: image.image.height))
            return try image.rgb(rect: rect, screen: rect, columns: 32, rows: 32)
        }
        // Two agreeing probes avoid treating a single animated transition as a
        // rotation. Ambiguous/symmetric pictures are not positive evidence.
        halfTurnConflicts =
            Self.halfTurnConflict(reference: try grid(image), preview: try grid(decoded))
            ? halfTurnConflicts + 1 : 0
        if halfTurnConflicts >= 2 { halfTurnConflicts = 0; return true }
        return false
    }

    static func halfTurnConflict(reference: Data, preview: Data) -> Bool {
        guard reference.count == preview.count, reference.count > 0, reference.count.isMultiple(of: 3) else {
            return false
        }
        let firstSample = Array(reference), secondSample = Array(preview), count = firstSample.count / 3
        var current = 0.0, opposite = 0.0
        for pixel in 0..<count {
            for channel in 0..<3 {
                let value = Int(firstSample[pixel * 3 + channel])
                current += Double(abs(value - Int(secondSample[pixel * 3 + channel])))
                opposite += Double(abs(value - Int(secondSample[(count - 1 - pixel) * 3 + channel])))
            }
        }
        current /= Double(firstSample.count * 255); opposite /= Double(firstSample.count * 255)
        return opposite < 0.08 && current - opposite > 0.025 && opposite < current * 0.5
    }
}

// Private, bounded transition diagnostics; no screenshots, packet payloads or UI text.
enum NativePreviewEvents {
    static func append(to url: URL, event: String, reason: String, source: [String: Any]) {
        var health = source
        if var snapshots = health["snapshots"] as? [String: Any] {
            snapshots.removeValue(forKey: "timing"); health["snapshots"] = snapshots
        }
        let facts: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "event": event, "reason": reason, "media": health
        ]
        guard let data = try? jsonData(facts) else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let file = try? FileHandle(forWritingTo: url) else { return }
        defer { try? file.close() }
        do {
            if try file.seekToEnd() > 1_048_576 { try file.truncate(atOffset: 0); try file.seek(toOffset: 0) }
            try file.write(contentsOf: data + Data([10]))
        } catch {} // Diagnostics never interrupt media/control.
    }
}
