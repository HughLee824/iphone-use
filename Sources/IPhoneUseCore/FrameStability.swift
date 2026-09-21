import Foundation
import CoreGraphics
import CryptoKit
import ImageIO

// Compiled into both the host and the device Runner. No encoded-image metadata enters the hash.
struct FrameFingerprint {
    let hash: String
    let width: Int
    let height: Int

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
        var digest = SHA256()
        let dimensions = [UInt64(width).bigEndian, UInt64(height).bigEndian]
        dimensions.withUnsafeBytes { digest.update(bufferPointer: $0) }
        digest.update(data: pixels)
        hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// Timestamps are monotonic and belong to post-input captures only.
struct FrameStability {
    static let sampleInterval: TimeInterval = 0.2
    static let stableDuration: TimeInterval = 0.4
    static let timeout: TimeInterval = 5
    private let startedAt: TimeInterval
    private var unchangedSince: TimeInterval
    private var lastSampleAt: TimeInterval
    private var processedAt: TimeInterval
    private(set) var hash: String?
    private(set) var samples = 0
    private(set) var consecutiveFrames = 0
    private(set) var stable = false

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
        unchangedSince = startedAt
        lastSampleAt = startedAt
        processedAt = startedAt
    }

    func remaining(at now: TimeInterval) -> TimeInterval { max(0, Self.timeout - (now - startedAt)) }

    mutating func record(hash: String, capturedAt: TimeInterval, processedAt: TimeInterval) {
        samples += 1
        lastSampleAt = capturedAt
        self.processedAt = processedAt
        if self.hash != hash {
            self.hash = hash
            unchangedSince = capturedAt
            consecutiveFrames = 1
        } else { consecutiveFrames += 1 }
        stable = remaining(at: processedAt) > 0 && consecutiveFrames >= 3
            && capturedAt - unchangedSince >= Self.stableDuration
    }

    var result: [String: Any] {
        ["stable": stable, "samples": samples, "consecutiveFrames": consecutiveFrames,
         "elapsedMs": (processedAt - startedAt) * 1000,
         "stableForMs": (lastSampleAt - unchangedSince) * 1000,
         "hash": hash as Any? ?? NSNull(), "algorithm": "sha256-rgba8-srgb",
         "sampleIntervalMs": Self.sampleInterval * 1000,
         "requiredStableMs": Self.stableDuration * 1000, "timeoutMs": Self.timeout * 1000]
    }
}
