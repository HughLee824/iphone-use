import Foundation
import CoreGraphics
import ImageIO

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
            """
            Input was not sent: the dynamic \(component) rectangle has insufficient visible shape features in\
             the baseline screenshot. Check screenshot-to-screen-point mapping and tightly bound the complete\
             visible control or page landmark. A fresh observation with unchanged rectangles will not repair\
             this; do not loosen thresholds.
            """
        }
        var diagnostics: [String: Any] {
            [
                "stage": "baseline_preparation", "component": component,
                "reason": "insufficient_shape_features", "coordinateSpace": "screen_points",
                "rect": ["x": rect.originX, "y": rect.originY, "width": rect.width, "height": rect.height]
            ]
        }
    }

    struct Check {
        let screenChange: Double
        let regionChanges: [Double]
        let policy: Policy
        var dynamicMatches: [Bool]?
        var fieldPixelsMatch: Bool?
        var fieldCaretMatch = false
        var caretObservationID: String?
        var fieldAppearanceMatch = false
        var caretRect: ScreenRect?
        var caretExclusionRect: ScreenRect?
        var ignoredRect: ScreenRect?
        var rawScreenChange: Double?
        var regionsAccepted: Bool {
            regionChanges.allSatisfy { $0 <= policy.maxRegionChange }
        }
        var accepted: Bool {
            if let dynamicMatches { return dynamicMatches.count == 2 && dynamicMatches.allSatisfy { $0 } }
            return screenChange <= policy.maxScreenChange
                && (regionsAccepted && fieldPixelsMatch != false || fieldCaretMatch || fieldAppearanceMatch)
        }
        var result: [String: Any] {
            var result: [String: Any] = [
                "algorithm": ignoredRect == nil ? ScreenGuard.algorithm : ScreenGuard.maskedAlgorithm,
                "accepted": accepted, "screenChange": screenChange,
                "regionChanges": regionChanges, "maxScreenChange": policy.maxScreenChange,
                "maxRegionChange": policy.maxRegionChange, "pixelTolerance": ScreenGuard.pixelTolerance
            ]
            if let dynamicMatches {
                result["algorithm"] = ScreenGuard.dynamicAlgorithm
                result["dynamicMatches"] = dynamicMatches
                result["validationScope"] = "explicit_target_and_anchor"
            }
            if let rect = ignoredRect {
                result["ignoredRect"] = [
                    "x": rect.originX, "y": rect.originY, "width": rect.width, "height": rect.height
                ]
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
                    result["caretRect"] = [
                        "x": caretRect.originX, "y": caretRect.originY, "width": caretRect.width,
                        "height": caretRect.height
                    ]
                }
                if let rect = caretExclusionRect {
                    result["caretExclusionRect"] = [
                        "x": rect.originX, "y": rect.originY, "width": rect.width, "height": rect.height
                    ]
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
            let gray = (0..<side * side).map { index in
                (Double(bytes[index * 3]) + Double(bytes[index * 3 + 1]) + Double(bytes[index * 3 + 2])) / 3
            }
            var result = Data(capacity: featureCount)
            for originY in radius..<(side - radius) {
                for originX in radius..<(side - radius) {
                    var sum = 0.0
                    for offsetY in -radius...radius {
                        for offsetX in -radius...radius {
                            sum += gray[(originY + offsetY) * side + originX + offsetX]
                        }
                    }
                    let value = (gray[originY * side + originX] - sum / 81).rounded()
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
            contrast = Self.features(
                try image.rgb(rect: rect, screen: screen, columns: Self.side, rows: Self.side))
            guard Self.usable(contrast) else { throw Failure.invalidGuard }
        }
        var valid: Bool { rect.valid && Self.usable(contrast) }
        func matches(image: ScreenImage, screen: ScreenRect) throws -> Bool {
            let current = Self.features(
                try image.rgb(rect: rect, screen: screen, columns: Self.side, rows: Self.side))
            guard Self.usable(current) else { return false }
            let originalEnergy = Self.energy(contrast), currentEnergy = Self.energy(current)
            let scale = sqrt(currentEnergy / originalEnergy)
            guard (0.2...5).contains(scale) else { return false }
            let dot = zip(contrast, current).reduce(0.0) { $0 + (Double($1.0) - 128) * (Double($1.1) - 128) }
            return dot / sqrt(originalEnergy * currentEnergy) >= 0.95
        }
    }

    init(
        png: Data, context: ScreenContext, rects: [ScreenRect], policy: Policy,
        ignoring ignoredRect: ScreenRect? = nil,
        dynamicRects: [ScreenRect]? = nil
    ) throws {
        guard context.valid, policy.valid, (1...Self.maximumRegions).contains(rects.count),
            rects.allSatisfy({ $0.valid && context.screen.cgRect.contains($0.cgRect) })
        else { throw Failure.invalidGuard }
        let image = try ScreenImage(png: png)
        try image.validateMapping(to: context.screen)
        algorithm =
            dynamicRects == nil
            ? (ignoredRect == nil ? Self.algorithm : Self.maskedAlgorithm) : Self.dynamicAlgorithm
        if let dynamicRects {
            // Reject malformed geometry/policy separately from an unusable image template.
            guard dynamicRects.count == 2, ignoredRect == nil,
                policy.maxScreenChange == 0.01, policy.maxRegionChange == 0,
                dynamicRects.allSatisfy({
                    $0.valid && context.scope.cgRect.contains($0.cgRect)
                        && $0.width <= 256 && $0.height <= 96
                }),
                dynamicRects[0].width <= 96,
                !dynamicRects[0].cgRect.intersects(dynamicRects[1].cgRect)
            else { throw Failure.invalidGuard }
        }
        dynamicOverlay = try dynamicRects.map { rects in
            try rects.enumerated().map { index, rect in
                do { return try OverlayGlyph(image: image, rect: rect, screen: context.screen) } catch Failure
                    .invalidGuard {
                    throw DynamicBaselineFailure(component: index == 0 ? "target" : "anchor", rect: rect)
                }
            }
        }
        self.ignoredRect = ignoredRect
        self.context = context
        self.policy = policy
        pixelWidth = image.image.width
        pixelHeight = image.image.height
        globalRGB = try image.rgb(
            rect: context.screen, screen: context.screen, columns: Self.globalColumns, rows: Self.globalRows)
        unmaskedRGB = try ignoredRect.map { rect in
            try Self.unmaskedRects(screen: context.screen, ignored: rect, protected: rects).map {
                let size = Self.bandGrid($0, screen: context.screen)
                return try image.areaRGB(
                    rect: $0, screen: context.screen, columns: size.columns, rows: size.rows)
            }
        }
        regions = try rects.map {
            Region(
                rect: $0,
                rgb: try image.rgb(
                    rect: $0, screen: context.screen, columns: Self.regionSide, rows: Self.regionSide))
        }
        try validate()
    }
}
