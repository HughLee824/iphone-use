import Foundation
import CoreImage

// Negative orientation evidence only. Never supplies observation pixels or an
// input coordinate transform. A conflict triggers an owned stop/read/rebind,
// after which CoreDevice supplies the authoritative orientation again.
final class NativePreviewOrientation {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var halfTurnConflicts = 0

    func needsRefresh(cli: AppleDeviceCLI, snapshots: NativeVideoSnapshot?, display: NativeDisplay) throws -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iphone-use-preview-direction-\(UUID().uuidString)")
        try SessionPaths.secureDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("screen.png")
        _ = try cli.read(["device", "capture", "screenshot", "--destination", destination.path], timeout: 3)
        let image = try ScreenImage(png: Data(contentsOf: destination))
        if image.image.width != Int(display.pixelWidth) || image.image.height != Int(display.pixelHeight) {
            halfTurnConflicts = 0
            return true
        }
        guard let frame = snapshots?.previewFrame() else { halfTurnConflicts = 0; return false }
        let jpeg = try NativePreview.encode(frame, display: display, context: context)
        let decoded = try ScreenImage(png: jpeg)
        func grid(_ image: ScreenImage) throws -> Data {
            let rect = ScreenRect(CGRect(x: 0, y: 0, width: image.image.width, height: image.image.height))
            return try image.rgb(rect: rect, screen: rect, columns: 32, rows: 32)
        }
        // Two agreeing probes avoid treating a single animated transition as a
        // rotation. Ambiguous/symmetric pictures are not positive evidence.
        halfTurnConflicts = Self.halfTurnConflict(reference: try grid(image), preview: try grid(decoded)) ? halfTurnConflicts + 1 : 0
        if halfTurnConflicts >= 2 { halfTurnConflicts = 0; return true }
        return false
    }

    static func halfTurnConflict(reference: Data, preview: Data) -> Bool {
        guard reference.count == preview.count, reference.count > 0, reference.count.isMultiple(of: 3) else { return false }
        let a = Array(reference), b = Array(preview), count = a.count / 3
        var current = 0.0, opposite = 0.0
        for pixel in 0..<count { for channel in 0..<3 {
            let value = Int(a[pixel * 3 + channel])
            current += Double(abs(value - Int(b[pixel * 3 + channel])))
            opposite += Double(abs(value - Int(b[(count - 1 - pixel) * 3 + channel])))
        } }
        current /= Double(a.count * 255); opposite /= Double(a.count * 255)
        return opposite < 0.08 && current - opposite > 0.025 && opposite < current * 0.5
    }
}
