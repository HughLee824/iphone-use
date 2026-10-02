import Foundation

// Compare every original field pixel. No color classifier, caret mask, OCR or
// resampling: a thin glyph must not disappear into the coarse screen grid.
// A tiny, spatially isolated low-contrast noise budget accommodates video
// quantization without accepting a connected stroke or a high-contrast edit.
struct NativeTextFieldGuard {
    private let context: ScreenContext
    private let field: ScreenRect
    fileprivate let width: Int
    fileprivate let height: Int
    fileprivate let source: Data

    init(png: Data, context: ScreenContext, field: ScreenRect) throws {
        guard context.valid, field.valid, context.screen.cgRect.contains(field.cgRect) else { throw ScreenGuard.Failure.invalidGuard }
        let image = try ScreenImage(png: png)
        try image.validateMapping(to: context.screen)
        let scale = Double(image.image.width) / context.screen.width
        let crop = CGRect(x: field.x * scale, y: field.y * scale, width: field.width * scale, height: field.height * scale).integral
        width = Int(crop.width); height = Int(crop.height)
        guard width > 0, height > 0, width * height <= 4_000_000 else { throw ScreenGuard.Failure.invalidGuard }
        source = try image.rgb(rect: field, screen: context.screen, columns: width, rows: height)
        self.context = context; self.field = field
    }

    fileprivate func pixels(png: Data, context current: ScreenContext) throws -> Data {
        guard context.matches(current) else { throw ScreenGuard.Failure.contextChanged }
        let image = try ScreenImage(png: png)
        try image.validateMapping(to: current.screen)
        return try image.rgb(rect: field, screen: current.screen, columns: width, rows: height)
    }

    func matches(png: Data, context current: ScreenContext) throws -> Bool {
        same(source, try pixels(png: png, context: current))
    }

    fileprivate var scale: Double { Double(width) / field.width }

    fileprivate func same(_ first: Data, _ next: Data) -> Bool {
        guard first.count == next.count else { return false }
        return first.withUnsafeBytes { (a: UnsafeRawBufferPointer) in
            next.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                var noise: [Int] = []
                for pixel in 0..<(width * height) {
                    let i = pixel * 3
                    let delta = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])),
                                    abs(Int(a[i + 2]) - Int(b[i + 2])))
                    if delta <= ScreenGuard.pixelTolerance { continue }
                    guard delta <= 16, noise.count < 4 else { return false }
                    let x = pixel % width, y = pixel / width
                    guard !noise.contains(where: { abs($0 % width - x) <= 1 && abs($0 / width - y) <= 1 }) else { return false }
                    noise.append(pixel)
                }
                return true
            }
        }
    }
}


// One instance per preflight, never shared across clipboard mutation or actions.
// A temporal exception requires an observed A-B-A cycle, confined to one narrow
// vertical stroke, and reconstructs ALL source pixels with one blend factor.
// Persistent text changes outside or inside that stroke still must match.
final class NativeTextPhaseMatcher {
    enum Match { case none, pixels, temporal }
    private let field: NativeTextFieldGuard
    private var frames: [Data] = []
    private var lastPNG: Data?
    private var lastMatch: Match = .none

    init(field: NativeTextFieldGuard) { self.field = field }

    func check(png: Data, context: ScreenContext) throws -> Match {
        let current = try field.pixels(png: png, context: context)
        if png == lastPNG { return lastMatch } // outer preflight rechecks the selected actual PNG
        defer { lastPNG = png }
        if field.same(field.source, current) { lastMatch = .pixels; return lastMatch }
        if frames.count >= 2 {
            for i in 0..<(frames.count - 1) where field.same(frames[i], current) {
                for j in (i + 1)..<frames.count where explainsSource(first: frames[i], other: frames[j]) {
                    lastMatch = .temporal
                    return lastMatch
                }
            }
        }
        if frames.count < 6 { frames.append(current) }
        lastMatch = .none
        return lastMatch
    }

    private func explainsSource(first: Data, other: Data) -> Bool {
        let a = [UInt8](first), b = [UInt8](other), source = [UInt8](field.source)
        var minX = field.width, maxX = -1, minY = field.height, maxY = -1, changed = 0
        var dot = 0.0, norm = 0.0, peak = 0
        var direction: [Int]?
        for pixel in 0..<(field.width * field.height) {
            let i = pixel * 3
            let delta = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2])))
            if delta <= 16 { continue }
            let x = pixel % field.width, y = pixel / field.width
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            changed += 1; peak = max(peak, delta)
            let vector = (0..<3).map { Int(b[i + $0]) - Int(a[i + $0]) }
            if let direction {
                // A moved stroke has opposing edges; a fading stroke does not.
                guard zip(direction, vector).reduce(0, { $0 + $1.0 * $1.1 }) > 0 else { return false }
            } else { direction = vector }
            for channel in 0..<3 {
                let d = Double(Int(b[i + channel]) - Int(a[i + channel]))
                dot += Double(Int(source[i + channel]) - Int(a[i + channel])) * d
                norm += d * d
            }
        }
        let w = maxX - minX + 1, h = maxY - minY + 1
        guard changed >= 12, peak > 16, norm > 0, w > 0, h > 0,
              Double(w) <= 4 * field.scale, Double(h) >= 8 * field.scale,
              Double(h) <= 80 * field.scale, h >= 3 * w,
              Double(changed) / Double(w * h) >= 0.3 else { return false }
        let alpha = dot / norm
        guard (0...1).contains(alpha) else { return false }
        var reconstructed = Data(count: a.count)
        reconstructed.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            for i in 0..<a.count { out[i] = UInt8((Double(a[i]) + Double(Int(b[i]) - Int(a[i])) * alpha).rounded()) }
        }
        return field.same(field.source, reconstructed)
    }
}
