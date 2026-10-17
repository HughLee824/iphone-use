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
    static let maskedAlgorithm = "srgb-area-excluded-rect-v2"
    static let dynamicAlgorithm = "bounded-overlay-contrast-v1"
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

    // A baseline failure happens before any live comparison or input dispatch.
    struct DynamicBaselineFailure: Error {
        let component: String
        let rect: ScreenRect

        var code: String { "dynamic_\(component)_unusable" }
        var message: String {
            "Input was not sent: the dynamic \(component) rectangle has insufficient visible shape features in the baseline screenshot. Check screenshot-to-screen-point mapping and tightly bound the complete visible control or page landmark. A fresh observation with unchanged rectangles will not repair this; do not loosen thresholds."
        }
        var diagnostics: [String: Any] {
            ["stage": "baseline_preparation", "component": component,
             "reason": "insufficient_shape_features", "coordinateSpace": "screen_points",
             "rect": ["x": rect.x, "y": rect.y, "width": rect.width, "height": rect.height]]
        }
    }

    struct Check {
        let screenChange: Double
        let regionChanges: [Double]
        let policy: Policy
        var dynamicMatches: [Bool]? = nil
        var fieldPixelsMatch: Bool? = nil
        var fieldCaretMatch = false
        var caretObservationID: String? = nil
        var fieldAppearanceMatch = false
        var caretRect: ScreenRect? = nil
        var caretExclusionRect: ScreenRect? = nil
        var ignoredRect: ScreenRect? = nil
        var rawScreenChange: Double? = nil
        var regionsAccepted: Bool {
            regionChanges.allSatisfy { $0 <= policy.maxRegionChange }
        }
        var accepted: Bool {
            if let dynamicMatches { return dynamicMatches.count == 2 && dynamicMatches.allSatisfy { $0 } }
            return screenChange <= policy.maxScreenChange
                && (regionsAccepted && fieldPixelsMatch != false || fieldCaretMatch || fieldAppearanceMatch)
        }
        var result: [String: Any] {
            var result: [String: Any] = ["algorithm": ignoredRect == nil ? ScreenGuard.algorithm : ScreenGuard.maskedAlgorithm, "accepted": accepted, "screenChange": screenChange,
             "regionChanges": regionChanges, "maxScreenChange": policy.maxScreenChange,
             "maxRegionChange": policy.maxRegionChange, "pixelTolerance": ScreenGuard.pixelTolerance]
            if let dynamicMatches {
                result["algorithm"] = ScreenGuard.dynamicAlgorithm
                result["dynamicMatches"] = dynamicMatches
                result["validationScope"] = "explicit_target_and_anchor"
            }
            if let rect = ignoredRect {
                result["ignoredRect"] = ["x": rect.x, "y": rect.y, "width": rect.width, "height": rect.height]
                result["rawScreenChange"] = rawScreenChange
                result["exclusionScope"] = "global_comparison_only"
            }
            if let fieldPixelsMatch {
                result["fieldPixelsMatch"] = fieldPixelsMatch
                result["fieldAlgorithm"] = "field-bound-caret-exclusion-v3"
                result["fieldCaretMatch"] = fieldCaretMatch
                result["caretObservationID"] = caretObservationID
                result["fieldAppearanceMatch"] = fieldAppearanceMatch
                if let caretRect {
                    result["caretRect"] = ["x": caretRect.x, "y": caretRect.y, "width": caretRect.width, "height": caretRect.height]
                }
                if let rect = caretExclusionRect {
                    result["caretExclusionRect"] = ["x": rect.x, "y": rect.y, "width": rect.width, "height": rect.height]
                }
            }
            return result
        }
    }

    let algorithm: String
    let context: ScreenContext
    let pixelWidth: Int
    let pixelHeight: Int
    let policy: Policy
    let globalRGB: Data
    let regions: [Region]
    let ignoredRect: ScreenRect?
    let unmaskedRGB: [Data]?
    let dynamicOverlay: [OverlayGlyph]?

    // Explicitly selected control + independent page landmark. Local contrast
    // retains stroke geometry while removing slowly varying video brightness,
    // including behind translucent controls. No search, alignment or tolerance
    // widening: both templates must match at their original coordinates.
    struct OverlayGlyph: Codable {
        let rect: ScreenRect
        let contrast: Data
        static let side = 64
        static let radius = 4
        static let featureCount = 56 * 56

        static func features(_ rgb: Data) -> Data {
            let bytes = Array(rgb)
            let gray = (0..<side * side).map { i in
                (Double(bytes[i * 3]) + Double(bytes[i * 3 + 1]) + Double(bytes[i * 3 + 2])) / 3
            }
            var result = Data(capacity: featureCount)
            for y in radius..<(side - radius) {
                for x in radius..<(side - radius) {
                    var sum = 0.0
                    for dy in -radius...radius {
                        for dx in -radius...radius { sum += gray[(y + dy) * side + x + dx] }
                    }
                    let value = (gray[y * side + x] - sum / 81).rounded()
                    result.append(UInt8(max(0, min(255, value + 128))))
                }
            }
            return result
        }
        static func energy(_ data: Data) -> Double {
            data.reduce(0.0) { $0 + pow(Double($1) - 128, 2) }
        }
        static func usable(_ data: Data) -> Bool {
            data.count == featureCount && energy(data) / Double(featureCount) >= 16
                && data.filter { $0 >= 136 }.count >= 48
                && data.filter { $0 <= 120 }.count >= 48
        }
        init(image: ScreenImage, rect: ScreenRect, screen: ScreenRect) throws {
            self.rect = rect
            contrast = Self.features(try image.rgb(rect: rect, screen: screen, columns: Self.side, rows: Self.side))
            guard Self.usable(contrast) else { throw Failure.invalidGuard }
        }
        var valid: Bool { rect.valid && Self.usable(contrast) }
        func matches(image: ScreenImage, screen: ScreenRect) throws -> Bool {
            let current = Self.features(try image.rgb(rect: rect, screen: screen, columns: Self.side, rows: Self.side))
            guard Self.usable(current) else { return false }
            let originalEnergy = Self.energy(contrast), currentEnergy = Self.energy(current)
            let scale = sqrt(currentEnergy / originalEnergy)
            guard (0.2...5).contains(scale) else { return false }
            let dot = zip(contrast, current).reduce(0.0) { $0 + (Double($1.0) - 128) * (Double($1.1) - 128) }
            return dot / sqrt(originalEnergy * currentEnergy) >= 0.95
        }
    }

    init(png: Data, context: ScreenContext, rects: [ScreenRect], policy: Policy, ignoring ignoredRect: ScreenRect? = nil, dynamicRects: [ScreenRect]? = nil) throws {
        guard context.valid, policy.valid, (1...Self.maximumRegions).contains(rects.count),
              rects.allSatisfy({ $0.valid && context.screen.cgRect.contains($0.cgRect) }) else { throw Failure.invalidGuard }
        let image = try ScreenImage(png: png)
        try image.validateMapping(to: context.screen)
        algorithm = dynamicRects == nil ? (ignoredRect == nil ? Self.algorithm : Self.maskedAlgorithm) : Self.dynamicAlgorithm
        if let dynamicRects {
            // Reject malformed geometry/policy separately from an unusable image template.
            guard dynamicRects.count == 2, ignoredRect == nil,
                  policy.maxScreenChange == 0.01, policy.maxRegionChange == 0,
                  dynamicRects.allSatisfy({ $0.valid && context.scope.cgRect.contains($0.cgRect)
                      && $0.width <= 256 && $0.height <= 96 }),
                  dynamicRects[0].width <= 96,
                  !dynamicRects[0].cgRect.intersects(dynamicRects[1].cgRect) else { throw Failure.invalidGuard }
        }
        dynamicOverlay = try dynamicRects.map { rects in
            try rects.enumerated().map { index, rect in
                do { return try OverlayGlyph(image: image, rect: rect, screen: context.screen) }
                catch Failure.invalidGuard {
                    throw DynamicBaselineFailure(component: index == 0 ? "target" : "anchor", rect: rect)
                }
            }
        }
        self.ignoredRect = ignoredRect
        self.context = context
        self.policy = policy
        pixelWidth = image.image.width
        pixelHeight = image.image.height
        globalRGB = try image.rgb(rect: context.screen, screen: context.screen, columns: Self.globalColumns, rows: Self.globalRows)
        unmaskedRGB = try ignoredRect.map { rect in
            try Self.unmaskedRects(screen: context.screen, ignored: rect, protected: rects).map {
                let size = Self.bandGrid($0, screen: context.screen)
                return try image.areaRGB(rect: $0, screen: context.screen, columns: size.columns, rows: size.rows)
            }
        }
        regions = try rects.map { Region(rect: $0, rgb: try image.rgb(rect: $0, screen: context.screen, columns: Self.regionSide, rows: Self.regionSide)) }
        try validate()
    }

    func validate() throws {
        guard algorithm == (dynamicOverlay == nil ? (ignoredRect == nil ? Self.algorithm : Self.maskedAlgorithm) : Self.dynamicAlgorithm), context.valid, policy.valid, pixelWidth > 0, pixelHeight > 0,
              globalRGB.count == Self.globalColumns * Self.globalRows * 3,
              (1...Self.maximumRegions).contains(regions.count),
              regions.allSatisfy({ $0.rect.valid && context.screen.cgRect.contains($0.rect.cgRect)
                  && $0.rgb.count == Self.regionSide * Self.regionSide * 3 }) else { throw Failure.invalidGuard }
        if let dynamicOverlay {
            guard dynamicOverlay.count == 2, ignoredRect == nil, unmaskedRGB == nil,
                  policy.maxScreenChange == 0.01, policy.maxRegionChange == 0,
                  dynamicOverlay.allSatisfy({ $0.valid && context.scope.cgRect.contains($0.rect.cgRect)
                      && $0.rect.width <= 256 && $0.rect.height <= 96 }),
                  dynamicOverlay[0].rect.width <= 96,
                  !dynamicOverlay[0].rect.cgRect.intersects(dynamicOverlay[1].rect.cgRect) else { throw Failure.invalidGuard }
        }
        if let ignoredRect {
            let rects = try Self.unmaskedRects(screen: context.screen, ignored: ignoredRect, protected: regions.map(\.rect))
            guard let unmaskedRGB, unmaskedRGB.count == rects.count,
                  zip(rects, unmaskedRGB).allSatisfy({ rect, rgb in
                      let size = Self.bandGrid(rect, screen: context.screen)
                      return rgb.count == size.columns * size.rows * 3
                  }) else { throw Failure.invalidGuard }
        } else if unmaskedRGB != nil { throw Failure.invalidGuard }
    }

    // One explicitly selected animation rectangle, never inferred from differences.
    // Its geometry is observation-bound and cannot consume an action/context region.
    private static func unmaskedRects(screen: ScreenRect, ignored: ScreenRect, protected: [ScreenRect]) throws -> [ScreenRect] {
        guard ignored.valid, screen.cgRect.contains(ignored.cgRect),
              ignored.width * ignored.height <= screen.width * screen.height * 0.25,
              protected.allSatisfy({ !$0.cgRect.intersects(ignored.cgRect) }) else { throw Failure.invalidGuard }
        let s = screen.cgRect, r = ignored.cgRect
        return [CGRect(x: s.minX, y: s.minY, width: s.width, height: r.minY - s.minY),
                CGRect(x: s.minX, y: r.maxY, width: s.width, height: s.maxY - r.maxY),
                CGRect(x: s.minX, y: r.minY, width: r.minX - s.minX, height: r.height),
                CGRect(x: r.maxX, y: r.minY, width: s.maxX - r.maxX, height: r.height)]
            .filter { $0.width > 0 && $0.height > 0 }.map(ScreenRect.init)
    }

    private static func bandGrid(_ rect: ScreenRect, screen: ScreenRect) -> (columns: Int, rows: Int) {
        (max(1, Int(ceil(Double(globalColumns) * rect.width / screen.width))),
         max(1, Int(ceil(Double(globalRows) * rect.height / screen.height))))
    }

    func check(png: Data, context current: ScreenContext) throws -> Check {
        try check(image: ScreenImage(png: png), context: current)
    }

    func check(image: ScreenImage, context current: ScreenContext) throws -> Check {
        try validate()
        guard context.matches(current) else { throw Failure.contextChanged }
        guard image.image.width == pixelWidth, image.image.height == pixelHeight else { throw Failure.contextChanged }
        try image.validateMapping(to: current.screen)
        let global = try image.rgb(rect: context.screen, screen: context.screen, columns: Self.globalColumns, rows: Self.globalRows)
        let raw = Self.changedFraction(globalRGB, global)
        if let dynamicOverlay {
            // Diagnostic only for this explicit scope; do not report an unchecked
            // moving background as zero change.
            return Check(screenChange: raw, regionChanges: [], policy: policy,
                         dynamicMatches: try dynamicOverlay.map { try $0.matches(image: image, screen: context.screen) })
        }
        let changes = try regions.map { region in
            Self.changedFraction(region.rgb, try image.rgb(rect: region.rect, screen: context.screen, columns: Self.regionSide, rows: Self.regionSide))
        }
        guard let ignoredRect, let unmaskedRGB else {
            return Check(screenChange: raw, regionChanges: changes, policy: policy)
        }
        let rects = try Self.unmaskedRects(screen: context.screen, ignored: ignoredRect, protected: regions.map(\.rect))
        // Crop each static band BEFORE reducing it. Average every native pixel
        // in each grid cell: interpolation can magnify a one-pixel video rim
        // into an entire changed cell. The exclusion geometry stays exact.
        var changedArea = 0.0, area = 0.0
        for (rect, rgb) in zip(rects, unmaskedRGB) {
            let grid = Self.bandGrid(rect, screen: context.screen)
            let current = try image.areaRGB(rect: rect, screen: context.screen, columns: grid.columns, rows: grid.rows)
            let size = rect.width * rect.height
            changedArea += Self.changedFraction(rgb, current) * size
            area += size
        }
        return Check(screenChange: changedArea / area, regionChanges: changes, policy: policy,
                     ignoredRect: ignoredRect, rawScreenChange: raw)
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

// Distances are the separation of two fingers along the current screenshot's X axis.
// They describe input geometry, not the scale that an app will apply.
struct PinchMotion: Codable, Equatable {
    let fromDistance: Double
    let toDistance: Double
    let duration: TimeInterval
    var valid: Bool {
        [fromDistance, toDistance, duration].allSatisfy(\.isFinite)
            && fromDistance >= 20 && toDistance >= 20
            && abs(fromDistance - toDistance) >= 1 && (0.1...5).contains(duration)
    }
    func points(center: CGPoint, ending: Bool) -> [CGPoint] {
        let half = (ending ? toDistance : fromDistance) / 2
        return [CGPoint(x: center.x - half, y: center.y), CGPoint(x: center.x + half, y: center.y)]
    }
    func regions(center: CGPoint, screen: CGRect) -> [ScreenRect] {
        zip(points(center: center, ending: false), points(center: center, ending: true)).map { start, end in
            ScreenRect(CGRect(x: min(start.x, end.x) - 32, y: start.y - 32,
                              width: abs(end.x - start.x) + 64, height: 64).intersection(screen))
        }
    }
    var result: [String: Any] { ["fromDistance": fromDistance, "toDistance": toDistance,
        "duration": duration, "axis": "screenshot_horizontal", "distanceUnit": "screen_points"] }
}

// XCTest's synthesized touch coordinates use the native portrait screen even
// when the screenshot and App frame are landscape. Keep guards in screenshot
// points; convert only at the Runner execution boundary.
enum RunnerCoordinateMapping {
    static func point(_ point: CGPoint, screen: ScreenRect, interfaceOrientation: Int) throws -> CGPoint {
        guard screen.valid, screen.cgRect.contains(point), (1...4).contains(interfaceOrientation) else {
            throw ScreenGuard.Failure.invalidGuard
        }
        let x = point.x - screen.x, y = point.y - screen.y
        switch interfaceOrientation {
        case 1: return CGPoint(x: x, y: y)
        case 2: return CGPoint(x: screen.width - x, y: screen.height - y)
        case 3: return CGPoint(x: screen.height - y, y: x)
        case 4: return CGPoint(x: y, y: screen.width - x)
        default: throw ScreenGuard.Failure.invalidGuard
        }
    }
}

struct CoordinateGesture: Codable {
    let start: CGPoint
    let end: CGPoint?
    let screenGuard: ScreenGuard
    var motion: SwipeMotion? = nil
    var pinch: PinchMotion? = nil

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
        if kind == "pinch" {
            guard let pinch, pinch.valid, end == nil, motion == nil,
                  [start.x, start.y].allSatisfy(\.isFinite),
                  (pinch.points(center: start, ending: false) + pinch.points(center: start, ending: true))
                    .allSatisfy({ $0.x.isFinite && $0.y.isFinite && screenGuard.context.scope.cgRect.contains($0) }) else {
                throw ScreenGuard.Failure.invalidGuard
            }
            let required = pinch.regions(center: start, screen: screenGuard.context.screen.cgRect)
            guard screenGuard.regions.prefix(2).map(\.rect) == required else { throw ScreenGuard.Failure.invalidGuard }
            return
        }
        guard pinch == nil, [start.x, start.y].allSatisfy(\.isFinite), screenGuard.context.scope.cgRect.contains(start),
              (["tap", "double-tap", "long-press"].contains(kind) && end == nil && motion == nil)
                || (kind == "swipe" && end != nil && motion?.valid == true && withinMotionBudget) else { throw ScreenGuard.Failure.invalidGuard }
        if let end {
            guard [end.x, end.y].allSatisfy(\.isFinite), screenGuard.context.scope.cgRect.contains(end),
                  hypot(end.x - start.x, end.y - start.y) >= 1 else { throw ScreenGuard.Failure.invalidGuard }
        }
        if let overlay = screenGuard.dynamicOverlay {
            guard kind == "tap", end == nil, overlay[0].rect.cgRect.contains(start) else { throw ScreenGuard.Failure.invalidGuard }
        }
        let required = Self.actionRegions(start: start, end: end, screen: screenGuard.context.screen.cgRect)
        guard screenGuard.regions.prefix(required.count).map(\.rect) == required else { throw ScreenGuard.Failure.invalidGuard }
    }
}

struct ScreenImage {
    let image: CGImage

    init(image: CGImage) { self.image = image }

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

    // Deterministic box averages for the coarse, unmasked global bands only.
    // Keep native field pixels and protected-region comparison unchanged.
    func areaRGB(rect: ScreenRect, screen: ScreenRect, columns: Int, rows: Int) throws -> Data {
        let scaleX = Double(image.width) / screen.width, scaleY = Double(image.height) / screen.height
        let pixels = CGRect(x: (rect.x - screen.x) * scaleX, y: (rect.y - screen.y) * scaleY,
                            width: rect.width * scaleX, height: rect.height * scaleY).integral
        guard let crop = image.cropping(to: pixels), columns > 0, rows > 0,
              columns <= crop.width, rows <= crop.height,
              crop.width <= 16_000_000 / crop.height else { throw ScreenGuard.Failure.invalidImage }
        let width = crop.width, height = crop.height
        // Render at native resolution: no interpolation before the average.
        let native = try rgb(rect: rect, screen: screen, columns: width, rows: height)
        var result = Data(count: columns * rows * 3)
        result.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            native.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                for row in 0..<rows {
                    let y0 = row * height / rows, y1 = (row + 1) * height / rows
                    for column in 0..<columns {
                        let x0 = column * width / columns, x1 = (column + 1) * width / columns
                        var red = 0, green = 0, blue = 0
                        for y in y0..<y1 {
                            for x in x0..<x1 {
                                let offset = (y * width + x) * 3
                                red += Int(source[offset]); green += Int(source[offset + 1]); blue += Int(source[offset + 2])
                            }
                        }
                        let count = (x1 - x0) * (y1 - y0), offset = (row * columns + column) * 3
                        out[offset] = UInt8((red + count / 2) / count)
                        out[offset + 1] = UInt8((green + count / 2) / count)
                        out[offset + 2] = UInt8((blue + count / 2) / count)
                    }
                }
            }
        }
        return result
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
        var rgb = Data(count: columns * rows * 3)
        rgb.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            rgba.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
                for pixel in 0..<(columns * rows) {
                    out[pixel * 3] = input[pixel * 4]
                    out[pixel * 3 + 1] = input[pixel * 4 + 1]
                    out[pixel * 3 + 2] = input[pixel * 4 + 2]
                }
            }
        }
        return rgb
    }
}
