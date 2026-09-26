import Foundation
import CoreGraphics
import CryptoKit
import ImageIO

// Compiled into both the host and the device Runner. No encoded-image metadata enters the hash.
struct FrameFingerprint {
    let hash: String
    let width: Int
    let height: Int
    let pixels: Data

    enum Failure: Error { case invalidImage }

    init(png: Data) throws {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(sourceWidth, sourceHeight)
              ] as CFDictionary), let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw Failure.invalidImage
        }
        let width = image.width
        let height = image.height
        self.width = width
        self.height = height
        var pixels = Data(count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw Failure.invalidImage
            }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        self.pixels = pixels
        var digest = SHA256()
        let dimensions = [UInt64(width).bigEndian, UInt64(height).bigEndian]
        dimensions.withUnsafeBytes { digest.update(bufferPointer: $0) }
        digest.update(data: pixels)
        hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // Diagnostic mask of ALL raw pixel differences, including tolerated color/caret
    // differences. Original screenshots remain untouched; this is never an observation.
    func differencePNG(from reference: FrameFingerprint) throws -> Data {
        guard width == reference.width, height == reference.height else { throw Failure.invalidImage }
        var mask = Data(repeating: 0, count: width * height * 4)
        mask.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            pixels.withUnsafeBytes { (a: UnsafeRawBufferPointer) in
                reference.pixels.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                    for i in stride(from: 0, to: out.count, by: 4) {
                        let changed = (0..<4).contains { a[i+$0] != b[i+$0] }
                        out[i] = changed ? 255 : 0; out[i+1] = out[i]; out[i+2] = out[i]; out[i+3] = 255
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: mask as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw Failure.invalidImage }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil) else { throw Failure.invalidImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.invalidImage }
        return encoded as Data
    }

}

// Image comparison is deliberately separate from the hash that binds the original PNG.
// Inspired by screenshot assertions: tolerate rendering noise, retain local changes.
// No resampling, global changed-area allowance, or automatic antialiasing suppression.
struct FrameComparison {
    static let algorithm = "yiq-local-caret-v1"
    static let colorTolerance = 2.5
    let changedPixels: Int
    let changedBounds: CGRect?
    let ignoredCaret: ScreenRect?
    let dimensionsMatch: Bool
    var equivalent: Bool { dimensionsMatch && changedPixels == 0 }

    init(reference: FrameFingerprint, current: FrameFingerprint, ignoredCaret: ScreenRect? = nil,
         screen: ScreenRect? = nil) {
        dimensionsMatch = reference.width == current.width && reference.height == current.height
        guard dimensionsMatch else {
            changedPixels = max(reference.width * reference.height, current.width * current.height)
            changedBounds = nil; self.ignoredCaret = nil; return
        }
        let mask: CGRect?
        if let ignoredCaret, let screen {
            let scale = Double(reference.width) / screen.width
            mask = CGRect(x: (ignoredCaret.x - screen.x) * scale, y: (ignoredCaret.y - screen.y) * scale,
                          width: ignoredCaret.width * scale, height: ignoredCaret.height * scale)
        } else { mask = nil }
        var count = 0, left = reference.width, top = reference.height, right = -1, bottom = -1
        reference.pixels.withUnsafeBytes { (a: UnsafeRawBufferPointer) in
            current.pixels.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                for y in 0..<reference.height {
                    let offset = y * reference.width * 4
                    // Compare every byte, but enter the Swift pixel loop only for
                    // changed rows. This matters for the unoptimized device Runner.
                    if memcmp(a.baseAddress!.advanced(by: offset), b.baseAddress!.advanced(by: offset), reference.width * 4) == 0 { continue }
                    for x in 0..<reference.width {
                        let i = (y * reference.width + x) * 4
                        if a[i] == b[i] && a[i+1] == b[i+1] && a[i+2] == b[i+2] && a[i+3] == b[i+3] { continue }
                        let r = Double(Int(a[i]) - Int(b[i])), g = Double(Int(a[i+1]) - Int(b[i+1]))
                        let blue = Double(Int(a[i+2]) - Int(b[i+2]))
                        // Standard YIQ components in 8-bit channel units, with a hard RGB cap.
                        // This bounds perceptual tolerance and keeps a single changed glyph significant.
                        let small = max(abs(r), abs(g), abs(blue)) <= 4 &&
                            max(abs(0.299*r + 0.587*g + 0.114*blue),
                                abs(0.596*r - 0.274*g - 0.322*blue),
                                abs(0.211*r - 0.523*g + 0.312*blue)) <= Self.colorTolerance
                        if a[i+3] == b[i+3] && (small || mask?.contains(CGPoint(x: x, y: y)) == true) { continue }
                        count += 1; left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                    }
                }
            }
        }
        changedPixels = count
        changedBounds = count == 0 ? nil : CGRect(x: left, y: top, width: right-left+1, height: bottom-top+1)
        self.ignoredCaret = ignoredCaret
    }

    var result: [String: Any] {
        var value: [String: Any] = ["equivalent": equivalent, "dimensionsMatch": dimensionsMatch,
            "changedPixels": changedPixels, "colorTolerance": Self.colorTolerance, "maxChannelDelta": 4]
        if let r = changedBounds { value["changedBoundsPixels"] = ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height] }
        if let r = ignoredCaret { value["ignoredCaret"] = ["x": r.x, "y": r.y, "width": r.width, "height": r.height] }
        return value
    }
}

// Timestamps are monotonic and belong to post-input captures only. Compare against
// a fixed candidate, not adjacent frames: small incremental drift must accumulate.
struct FrameStability {
    static let sampleInterval: TimeInterval = 0.2
    static let stableDuration: TimeInterval = 0.4
    static let minimumObservationDuration: TimeInterval = 1.5
    static let timeout: TimeInterval = 5
    private let startedAt: TimeInterval
    private let context: ScreenContext?
    private let textFields: [ScreenRect]
    private var unchangedSince: TimeInterval
    private var lastSampleAt: TimeInterval
    private var processedAt: TimeInterval
    private var anchor: FrameFingerprint?
    private var anchorPNG: Data?
    private var caret: NativeCaretGuard?
    private var comparison: FrameComparison?
    private(set) var comparisonReferencePNG: Data?
    private(set) var comparisonReferenceHash: String?
    private(set) var hash: String?
    private(set) var samples = 0
    private(set) var consecutiveFrames = 0
    private(set) var stable = false

    init(startedAt: TimeInterval, context: ScreenContext? = nil, textFields: [ScreenRect] = []) {
        self.startedAt = startedAt; self.context = context; self.textFields = textFields.count <= 8 ? textFields : []
        unchangedSince = startedAt; lastSampleAt = startedAt; processedAt = startedAt
    }

    func remaining(at now: TimeInterval) -> TimeInterval { max(0, Self.timeout - (now - startedAt)) }

    mutating func record(frame: FrameFingerprint, png: Data, capturedAt: TimeInterval, processedAt: @autoclosure () -> TimeInterval) {
        comparisonReferencePNG = anchorPNG
        comparisonReferenceHash = anchor?.hash
        var ignored: ScreenRect?
        if anchor?.hash != frame.hash, let caret, let context,
           (try? caret.acceptsBlink(png: png, context: context)) == true { ignored = caret.caret }
        comparison = anchor.map { FrameComparison(reference: $0, current: frame, ignoredCaret: ignored, screen: context?.screen) }
        let equivalent = comparison?.equivalent == true
        if !equivalent {
            anchor = frame; anchorPNG = png; caret = nil
            if let context {
                let candidates = textFields.compactMap { field in
                    try? NativeCaretGuard(png: png, context: context, field: field, allowsAdjacentText: true, allowsYellowCaret: false)
                }
                // At most one recognized stroke across all bounded fields. The
                // full frame is still compared, including all other field pixels.
                if candidates.count == 1 { caret = candidates[0] }
            }
        }
        recordSample(hash: frame.hash, equivalent: equivalent, capturedAt: capturedAt, processedAt: processedAt())
    }

    private mutating func recordSample(hash: String, equivalent: Bool, capturedAt: TimeInterval, processedAt: TimeInterval) {
        samples += 1; lastSampleAt = capturedAt; self.processedAt = processedAt; self.hash = hash
        if !equivalent { unchangedSince = capturedAt; consecutiveFrames = 1 }
        else { consecutiveFrames += 1 }
        stable = remaining(at: processedAt) > 0 && consecutiveFrames >= 3
            && capturedAt - unchangedSince >= Self.stableDuration
            && capturedAt - startedAt >= Self.minimumObservationDuration
    }

    var result: [String: Any] {
        var value: [String: Any] = ["stable": stable, "samples": samples, "consecutiveFrames": consecutiveFrames,
            "elapsedMs": (processedAt - startedAt) * 1000, "observedForMs": (lastSampleAt - startedAt) * 1000,
            "stableForMs": (lastSampleAt - unchangedSince) * 1000,
            "hash": hash as Any? ?? NSNull(), "algorithm": FrameComparison.algorithm,
            "sampleIntervalMs": Self.sampleInterval * 1000, "minimumObservationMs": Self.minimumObservationDuration * 1000,
            "requiredStableMs": Self.stableDuration * 1000, "timeoutMs": Self.timeout * 1000]
        value["comparison"] = comparison?.result
        value["referenceHash"] = comparisonReferenceHash
        return value
    }
}
