import Foundation
import CoreGraphics
import CryptoKit
import ImageIO

// Compiled into both the host and the device Runner. No encoded-image metadata enters the hash.
public struct FrameFingerprint {
    public let hash: String
    public let width: Int
    public let height: Int
    let pixels: Data

    public enum Failure: Error { case invalidImage }

    public init(png: Data) throws {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
            let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int,
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(sourceWidth, sourceHeight)
                ] as CFDictionary), let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            throw Failure.invalidImage
        }
        let width = image.width
        let height = image.height
        self.width = width
        self.height = height
        var pixels = Data(count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue)
            else {
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
    public func differencePNG(from reference: FrameFingerprint) throws -> Data {
        guard width == reference.width, height == reference.height else { throw Failure.invalidImage }
        var mask = Data(repeating: 0, count: width * height * 4)
        mask.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            pixels.withUnsafeBytes { (firstSample: UnsafeRawBufferPointer) in
                reference.pixels.withUnsafeBytes { (secondSample: UnsafeRawBufferPointer) in
                    for index in stride(from: 0, to: out.count, by: 4) {
                        let changed = (0..<4).contains { firstSample[index + $0] != secondSample[index + $0] }
                        out[index] = changed ? 255 : 0; out[index + 1] = out[index]
                        out[index + 2] = out[index]
                        out[index + 3] = 255
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: mask as CFData),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw Failure.invalidImage }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil)
        else {
            throw Failure.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.invalidImage }
        return encoded as Data
    }

}

// Image comparison is deliberately separate from the hash that binds the original PNG.
// Inspired by screenshot assertions: tolerate rendering noise, retain local changes.
// No resampling, global changed-area allowance, or automatic antialiasing suppression.
public struct FrameComparison {
    public static let algorithm = "yiq-local-caret-v1"
    public static let colorTolerance = 2.5
    public let changedPixels: Int
    public let changedBounds: CGRect?
    public let ignoredCaret: ScreenRect?
    public let dimensionsMatch: Bool
    public var equivalent: Bool { dimensionsMatch && changedPixels == 0 }

    public init(
        reference: FrameFingerprint, current: FrameFingerprint, ignoredCaret: ScreenRect? = nil,
        screen: ScreenRect? = nil
    ) {
        dimensionsMatch = reference.width == current.width && reference.height == current.height
        guard dimensionsMatch else {
            changedPixels = max(reference.width * reference.height, current.width * current.height)
            changedBounds = nil; self.ignoredCaret = nil; return
        }
        let mask: CGRect?
        if let ignoredCaret, let screen {
            let scale = Double(reference.width) / screen.width
            mask = CGRect(
                x: (ignoredCaret.originX - screen.originX) * scale,
                y: (ignoredCaret.originY - screen.originY) * scale,
                width: ignoredCaret.width * scale, height: ignoredCaret.height * scale)
        } else {
            mask = nil
        }
        var count = 0, left = reference.width, top = reference.height, right = -1, bottom = -1
        reference.pixels.withUnsafeBytes { (firstSample: UnsafeRawBufferPointer) in
            current.pixels.withUnsafeBytes { (secondSample: UnsafeRawBufferPointer) in
                for row in 0..<reference.height {
                    let offset = row * reference.width * 4
                    // Compare every byte, but enter the Swift pixel loop only for
                    // changed rows. This matters for the unoptimized device Runner.
                    if memcmp(
                        firstSample.baseAddress!.advanced(by: offset),
                        secondSample.baseAddress!.advanced(by: offset),
                        reference.width * 4)
                        == 0 {
                        continue
                    }
                    for column in 0..<reference.width {
                        let index = (row * reference.width + column) * 4
                        if firstSample[index] == secondSample[index]
                            && firstSample[index + 1] == secondSample[index + 1]
                            && firstSample[index + 2] == secondSample[index + 2]
                            && firstSample[index + 3] == secondSample[index + 3] {
                            continue
                        }
                        let small = Self.isSmallColorChange(firstSample, secondSample, index: index)
                        if firstSample[index + 3] == secondSample[index + 3]
                            && (small || mask?.contains(CGPoint(x: column, y: row)) == true) {
                            continue
                        }
                        count += 1; left = min(left, column); right = max(right, column); top = min(top, row)
                        bottom = max(bottom, row)
                    }
                }
            }
        }
        changedPixels = count
        changedBounds =
            count == 0 ? nil : CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        self.ignoredCaret = ignoredCaret
    }

    private static func isSmallColorChange(
        _ firstSample: UnsafeRawBufferPointer,
        _ secondSample: UnsafeRawBufferPointer, index: Int
    ) -> Bool {
        let red = Double(Int(firstSample[index]) - Int(secondSample[index])),
            green = Double(Int(firstSample[index + 1]) - Int(secondSample[index + 1]))
        let blue = Double(Int(firstSample[index + 2]) - Int(secondSample[index + 2]))
        // Standard YIQ components in 8-bit channel units, with a hard RGB cap.
        // This bounds perceptual tolerance and keeps a single changed glyph significant.
        return
            max(abs(red), abs(green), abs(blue)) <= 4
            && max(
                abs(0.299 * red + 0.587 * green + 0.114 * blue),
                abs(0.596 * red - 0.274 * green - 0.322 * blue),
                abs(0.211 * red - 0.523 * green + 0.312 * blue)) <= Self.colorTolerance
    }

    public var result: [String: Any] {
        var value: [String: Any] = [
            "equivalent": equivalent, "dimensionsMatch": dimensionsMatch,
            "changedPixels": changedPixels, "colorTolerance": Self.colorTolerance, "maxChannelDelta": 4
        ]
        if let bounds = changedBounds {
            value["changedBoundsPixels"] = [
                "x": bounds.minX, "y": bounds.minY, "width": bounds.width, "height": bounds.height
            ]
        }
        if let bounds = ignoredCaret {
            value["ignoredCaret"] = [
                "x": bounds.originX, "y": bounds.originY, "width": bounds.width, "height": bounds.height
            ]
        }
        return value
    }
}

// Timestamps are monotonic and belong to post-input captures only. Compare against
// a fixed candidate, not adjacent frames: small incremental drift must accumulate.
public struct FrameStability {
    public static let sampleInterval: TimeInterval = 0.2
    public static let stableDuration: TimeInterval = 0.4
    public static let minimumObservationDuration: TimeInterval = 1.5
    public static let timeout: TimeInterval = 5
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
    public private(set) var comparisonReferencePNG: Data?
    public private(set) var comparisonReferenceHash: String?
    public private(set) var hash: String?
    public private(set) var samples = 0
    public private(set) var consecutiveFrames = 0
    public private(set) var stable = false

    public init(startedAt: TimeInterval, context: ScreenContext? = nil, textFields: [ScreenRect] = []) {
        self.startedAt = startedAt; self.context = context
        self.textFields = textFields.count <= 8 ? textFields : []
        unchangedSince = startedAt; lastSampleAt = startedAt; processedAt = startedAt
    }

    public func remaining(at now: TimeInterval) -> TimeInterval { max(0, Self.timeout - (now - startedAt)) }

    public mutating func record(
        frame: FrameFingerprint, png: Data, capturedAt: TimeInterval,
        processedAt: @autoclosure () -> TimeInterval
    ) {
        comparisonReferencePNG = anchorPNG
        comparisonReferenceHash = anchor?.hash
        var ignored: ScreenRect?
        if anchor?.hash != frame.hash, let caret, let context,
            (try? caret.acceptsBlink(png: png, context: context)) == true {
            ignored = caret.caret
        }
        comparison = anchor.map {
            FrameComparison(reference: $0, current: frame, ignoredCaret: ignored, screen: context?.screen)
        }
        let equivalent = comparison?.equivalent == true
        if !equivalent {
            anchor = frame; anchorPNG = png; caret = nil
            if let context {
                let candidates = textFields.compactMap { field in
                    try? NativeCaretGuard(
                        png: png, context: context, field: field, allowsAdjacentText: true,
                        allowsColoredCarets: false)
                }
                // At most one recognized stroke across all bounded fields. The
                // full frame is still compared, including all other field pixels.
                if candidates.count == 1 { caret = candidates[0] }
            }
        }
        recordSample(
            hash: frame.hash, equivalent: equivalent, capturedAt: capturedAt, processedAt: processedAt())
    }

    private mutating func recordSample(
        hash: String, equivalent: Bool, capturedAt: TimeInterval, processedAt: TimeInterval
    ) {
        samples += 1; lastSampleAt = capturedAt; self.processedAt = processedAt; self.hash = hash
        if !equivalent { unchangedSince = capturedAt; consecutiveFrames = 1 } else { consecutiveFrames += 1 }
        stable =
            remaining(at: processedAt) > 0 && consecutiveFrames >= 3
            && capturedAt - unchangedSince >= Self.stableDuration
            && capturedAt - startedAt >= Self.minimumObservationDuration
    }

    // A fresh view of a moving page is useful even when it never becomes still.
    // This is not permission for the next input; its observation guard still runs.
    public var observationReady: Bool {
        samples >= 3 && lastSampleAt - startedAt >= Self.minimumObservationDuration
    }

    public var result: [String: Any] {
        var value: [String: Any] = [
            "stable": stable,
            "reason": stable
                ? "stable" : (observationReady ? "dynamic_or_transitioning" : "insufficient_samples"),
            "automaticReplayAllowed": false, "samples": samples, "consecutiveFrames": consecutiveFrames,
            "elapsedMs": (processedAt - startedAt) * 1000, "observedForMs": (lastSampleAt - startedAt) * 1000,
            "stableForMs": (lastSampleAt - unchangedSince) * 1000,
            "hash": hash as Any? ?? NSNull(), "algorithm": FrameComparison.algorithm,
            "sampleIntervalMs": Self.sampleInterval * 1000,
            "minimumObservationMs": Self.minimumObservationDuration * 1000,
            "requiredStableMs": Self.stableDuration * 1000, "timeoutMs": Self.timeout * 1000
        ]
        value["comparison"] = comparison?.result
        value["referenceHash"] = comparisonReferenceHash
        return value
    }
}
