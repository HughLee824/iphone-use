import Foundation
import CoreGraphics

// An optional, source-anchored exception for a single blue UIKit-style caret.
// Never infer a caret from a difference alone: a hidden source has no anchor.
// This is pixel evidence, not independent confirmation of editor focus.
struct NativeCaretGuard {
    private let context: ScreenContext
    private let field: ScreenRect
    private let width: Int
    private let height: Int
    private let source: [UInt8]
    private let background: [Int]
    private let bounds: CGRect
    private let reference: Int
    private let referenceChannel: Int
    let caret: ScreenRect

    init?(png: Data, context: ScreenContext, field: ScreenRect) throws {
        guard context.valid, field.valid, context.screen.cgRect.contains(field.cgRect) else { return nil }
        let image = try ScreenImage(png: png)
        try image.validateMapping(to: context.screen)
        let scale = Double(image.image.width) / context.screen.width
        let crop = CGRect(x: field.x * scale, y: field.y * scale, width: field.width * scale, height: field.height * scale).integral
        let width = Int(crop.width), height = Int(crop.height)
        guard width > 0, height > 0, width * height <= 4_000_000 else { return nil }
        let source = [UInt8](try image.rgb(rect: field, screen: context.screen, columns: width, rows: height))
        var left = width, right = -1, top = height, bottom = -1, count = 0
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 3
            let r = Int(source[i]), g = Int(source[i + 1]), b = Int(source[i + 2])
            if b >= 70 && b - r >= 30 && b - g >= 15 {
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y); count += 1
            }
        } }
        let w = right - left + 1, h = bottom - top + 1
        guard count > 0, Double(w) >= scale, Double(w) <= 3 * scale,
              Double(h) >= 8 * scale, Double(h) <= 40 * scale,
              Double(count) / Double(w * h) >= 0.85,
              left >= 3, top >= 3, right + 3 < width, bottom + 3 < height else { return nil }
        // One antialiasing pixel around the detected stroke. The next surrounding
        // ring must be uniform, so adjacent text/selection handles cannot be erased.
        let bounds = CGRect(x: left - 1, y: top - 1, width: w + 2, height: h + 2)
        let bgIndex = ((top - 2) * width + left - 2) * 3
        let background = (0..<3).map { Int(source[bgIndex + $0]) }
        for y in (top - 2)...(bottom + 2) { for x in (left - 2)...(right + 2) {
            if bounds.contains(CGPoint(x: x, y: y)) { continue }
            let i = (y * width + x) * 3
            guard (0..<3).allSatisfy({ abs(Int(source[i + $0]) - background[$0]) <= ScreenGuard.pixelTolerance }) else { return nil }
        } }
        // Use the strongest color contrast to estimate a single fade factor. The
        // entire stroke must fit that factor; a changed shape is not a blink.
        var reference = (top * width + left) * 3, referenceChannel = 0, contrast = 0
        for y in top...bottom { for x in left...right {
            let i = (y * width + x) * 3
            for channel in 0..<3 {
                let value = abs(Int(source[i + channel]) - background[channel])
                if value > contrast { contrast = value; reference = i; referenceChannel = channel }
            }
        } }
        guard contrast >= 40 else { return nil }
        self.context = context; self.field = field; self.width = width; self.height = height
        self.source = source; self.background = background; self.bounds = bounds; self.reference = reference
        self.referenceChannel = referenceChannel
        caret = ScreenRect(CGRect(x: (crop.minX + Double(left)) / scale, y: (crop.minY + Double(top)) / scale,
                                 width: Double(w) / scale, height: Double(h) / scale))
    }

    func acceptsBlink(png: Data, context current: ScreenContext) throws -> Bool {
        guard context.matches(current) else { return false }
        let image = try ScreenImage(png: png)
        try image.validateMapping(to: current.screen)
        let scale = Double(image.image.width) / current.screen.width
        let crop = CGRect(x: field.x * scale, y: field.y * scale, width: field.width * scale, height: field.height * scale).integral
        guard Int(crop.width) == width, Int(crop.height) == height else { return false }
        let next = [UInt8](try image.rgb(rect: field, screen: current.screen, columns: width, rows: height))
        let factor = Double(Int(next[reference + referenceChannel]) - background[referenceChannel])
            / Double(Int(source[reference + referenceChannel]) - background[referenceChannel])
        guard factor >= 0, factor <= 6 else { return false }
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 3
            let inside = bounds.contains(CGPoint(x: x, y: y))
            for channel in 0..<3 {
                let expected = inside
                    ? Double(background[channel]) + Double(Int(source[i + channel]) - background[channel]) * factor
                    : Double(source[i + channel])
                guard abs(Double(next[i + channel]) - expected) <= Double(ScreenGuard.pixelTolerance) else { return false }
            }
        } }
        return true
    }
}
