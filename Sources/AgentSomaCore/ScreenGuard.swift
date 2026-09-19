import Foundation
import CoreGraphics
import ImageIO

// Shared, bounded device facts and comparison code. No refs, AX lookup, cache or recovery policy.
struct ScreenRect: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var valid: Bool { [x, y, width, height, x + width, y + height].allSatisfy(\.isFinite) && width > 0 && height > 0 }

    func matches(_ other: ScreenRect) -> Bool {
        zip([x, y, width, height], [other.x, other.y, other.width, other.height]).allSatisfy { abs($0 - $1) <= 0.5 }
    }
}

struct ScreenContext: Codable {
    let screen: ScreenRect
    let scope: ScreenRect
    let orientation: Int
    let keyboardCount: Int

    var valid: Bool {
        screen.valid && scope.valid && screen.x == 0 && screen.y == 0 && screen.cgRect.contains(scope.cgRect)
            && (0...6).contains(orientation) && keyboardCount >= 0
    }

    func matches(_ other: ScreenContext) -> Bool {
        valid && other.valid && screen.matches(other.screen) && scope.matches(other.scope)
            && orientation == other.orientation && keyboardCount == other.keyboardCount
    }
}

struct ScreenGuard: Codable {
    static let algorithm = "srgb-grid-v1"
    static let maximumRegions = 5
    static let pixelTolerance = 8
    static let globalColumns = 32
    static let globalRows = 64
    static let regionSide = 48

    struct Policy: Codable {
        // Conservative engineering defaults, not calibrated probabilities of target correctness.
        var maxScreenChange = 0.01
        var maxRegionChange = 0.0
        var valid: Bool {
            [maxScreenChange, maxRegionChange].allSatisfy { $0.isFinite && (0...1).contains($0) }
                && maxRegionChange <= maxScreenChange
        }
    }

    struct Region: Codable {
        let rect: ScreenRect
        let rgb: Data
    }

    enum Failure: String, Error {
        case invalidGuard = "invalid_screen_guard"
        case invalidImage = "screen_guard_image_unavailable"
        case contextChanged = "screen_context_changed"
    }

    struct Check {
        let screenChange: Double
        let regionChanges: [Double]
        let policy: Policy
        var accepted: Bool { screenChange <= policy.maxScreenChange && regionChanges.allSatisfy { $0 <= policy.maxRegionChange } }
        var result: [String: Any] {
            ["algorithm": ScreenGuard.algorithm, "accepted": accepted, "screenChange": screenChange,
             "regionChanges": regionChanges, "maxScreenChange": policy.maxScreenChange,
             "maxRegionChange": policy.maxRegionChange, "pixelTolerance": ScreenGuard.pixelTolerance]
        }
    }

    let algorithm: String
    let context: ScreenContext
    let pixelWidth: Int
    let pixelHeight: Int
    let policy: Policy
    let globalRGB: Data
    let regions: [Region]

    init(png: Data, context: ScreenContext, rects: [ScreenRect], policy: Policy) throws {
        guard context.valid, policy.valid, (1...Self.maximumRegions).contains(rects.count),
              rects.allSatisfy({ $0.valid && context.screen.cgRect.contains($0.cgRect) }) else { throw Failure.invalidGuard }
        let image = try ScreenImage(png: png)
        try image.validateMapping(to: context.screen)
        algorithm = Self.algorithm
        self.context = context
        self.policy = policy
        pixelWidth = image.image.width
        pixelHeight = image.image.height
        globalRGB = try image.rgb(rect: context.screen, screen: context.screen, columns: Self.globalColumns, rows: Self.globalRows)
        regions = try rects.map { Region(rect: $0, rgb: try image.rgb(rect: $0, screen: context.screen, columns: Self.regionSide, rows: Self.regionSide)) }
    }

    func validate() throws {
        guard algorithm == Self.algorithm, context.valid, policy.valid, pixelWidth > 0, pixelHeight > 0,
              globalRGB.count == Self.globalColumns * Self.globalRows * 3,
              (1...Self.maximumRegions).contains(regions.count),
              regions.allSatisfy({ $0.rect.valid && context.screen.cgRect.contains($0.rect.cgRect)
                  && $0.rgb.count == Self.regionSide * Self.regionSide * 3 }) else { throw Failure.invalidGuard }
    }

    func check(png: Data, context current: ScreenContext) throws -> Check {
        try validate()
        guard context.matches(current) else { throw Failure.contextChanged }
        let image = try ScreenImage(png: png)
        guard image.image.width == pixelWidth, image.image.height == pixelHeight else { throw Failure.contextChanged }
        try image.validateMapping(to: current.screen)
        let global = try image.rgb(rect: context.screen, screen: context.screen, columns: Self.globalColumns, rows: Self.globalRows)
        let changes = try regions.map { region in
            Self.changedFraction(region.rgb, try image.rgb(rect: region.rect, screen: context.screen, columns: Self.regionSide, rows: Self.regionSide))
        }
        return Check(screenChange: Self.changedFraction(globalRGB, global), regionChanges: changes, policy: policy)
    }

    // Fraction of grid cells with at least one RGB channel differing by more than the noise floor.
    private static func changedFraction(_ lhs: Data, _ rhs: Data) -> Double {
        let a = [UInt8](lhs), b = [UInt8](rhs)
        var changed = 0
        for index in stride(from: 0, to: a.count, by: 3) {
            if (0..<3).contains(where: { abs(Int(a[index + $0]) - Int(b[index + $0])) > pixelTolerance }) { changed += 1 }
        }
        return Double(changed) / Double(a.count / 3)
    }
}

struct SwipeMotion: Codable, Equatable {
    static let maximumEstimatedDuration: TimeInterval = 10
    var velocity = 500.0
    var pressDuration = 0.0
    var holdDuration = 0.0

    var valid: Bool {
        [velocity, pressDuration, holdDuration].allSatisfy(\.isFinite)
            && velocity > 0 && velocity <= 10_000
            && (0...5).contains(pressDuration) && (0...5).contains(holdDuration)
    }

    var result: [String: Any] {
        ["velocity": velocity, "pressDuration": pressDuration, "holdDuration": holdDuration]
    }
}

struct CoordinateGesture: Codable {
    let start: CGPoint
    let end: CGPoint?
    let screenGuard: ScreenGuard
    var motion: SwipeMotion? = nil

    var withinMotionBudget: Bool {
        guard let end, let motion else { return true }
        // XCTest documents velocity in pixels/s. Use screenshot scale for a conservative
        // estimate; this bounds requested motion, not the runtime's idle/capture overhead.
        let scale = max(Double(screenGuard.pixelWidth) / screenGuard.context.screen.width,
                        Double(screenGuard.pixelHeight) / screenGuard.context.screen.height)
        let duration = motion.pressDuration + hypot(end.x - start.x, end.y - start.y) * scale / motion.velocity + motion.holdDuration
        return motion.valid && duration.isFinite && duration <= SwipeMotion.maximumEstimatedDuration
    }

    // Always protect the touch-down neighborhood; also protect the entire swipe corridor.
    static func actionRegions(start: CGPoint, end: CGPoint?, screen: CGRect) -> [ScreenRect] {
        var rects = [CGRect(x: start.x - 32, y: start.y - 32, width: 64, height: 64)]
        if let end {
            rects.append(CGRect(x: min(start.x, end.x) - 16, y: min(start.y, end.y) - 16,
                               width: abs(start.x - end.x) + 32, height: abs(start.y - end.y) + 32))
        }
        return rects.map { ScreenRect($0.intersection(screen)) }
    }

    func validate(kind: String) throws {
        try screenGuard.validate()
        guard [start.x, start.y].allSatisfy(\.isFinite), screenGuard.context.scope.cgRect.contains(start),
              (kind == "tap" && end == nil && motion == nil)
                || (kind == "swipe" && end != nil && motion?.valid == true && withinMotionBudget) else { throw ScreenGuard.Failure.invalidGuard }
        if let end {
            guard [end.x, end.y].allSatisfy(\.isFinite), screenGuard.context.scope.cgRect.contains(end),
                  hypot(end.x - start.x, end.y - start.y) >= 1 else { throw ScreenGuard.Failure.invalidGuard }
        }
        let required = Self.actionRegions(start: start, end: end, screen: screenGuard.context.screen.cgRect)
        guard screenGuard.regions.prefix(required.count).map(\.rect) == required else { throw ScreenGuard.Failure.invalidGuard }
    }
}

struct ScreenImage {
    let image: CGImage

    init(png: Data) throws {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height)
              ] as CFDictionary) else { throw ScreenGuard.Failure.invalidImage }
        self.image = image
    }

    func validateMapping(to screen: ScreenRect) throws {
        // Full-screen iPhone captures only; never stretch a mismatched image onto old coordinates.
        let scaleX = Double(image.width) / screen.width, scaleY = Double(image.height) / screen.height
        guard scaleX >= 1, scaleY >= 1, abs(scaleX - scaleY) <= 0.01 else { throw ScreenGuard.Failure.invalidImage }
    }

    func rgb(rect: ScreenRect, screen: ScreenRect, columns: Int, rows: Int) throws -> Data {
        let scaleX = Double(image.width) / screen.width, scaleY = Double(image.height) / screen.height
        let pixels = CGRect(x: (rect.x - screen.x) * scaleX, y: (rect.y - screen.y) * scaleY,
                            width: rect.width * scaleX, height: rect.height * scaleY).integral
        guard let crop = image.cropping(to: pixels), let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ScreenGuard.Failure.invalidImage
        }
        var rgba = [UInt8](repeating: 0, count: columns * rows * 4)
        try rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: columns, height: rows,
                bitsPerComponent: 8, bytesPerRow: columns * 4, space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ScreenGuard.Failure.invalidImage
            }
            context.setBlendMode(.copy)
            context.interpolationQuality = .high
            context.draw(crop, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        }
        var rgb = Data(capacity: columns * rows * 3)
        for index in stride(from: 0, to: rgba.count, by: 4) { rgb.append(contentsOf: rgba[index..<(index + 3)]) }
        return rgb
    }
}
