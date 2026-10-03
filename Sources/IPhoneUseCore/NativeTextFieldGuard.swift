import Foundation

// ScreenGuard is also compiled into Runner. Keep the native matcher adapter
// here so that shared screen comparison does not depend on native-only types.
extension ScreenGuard.Check {
    mutating func apply(_ match: NativeTextPhaseMatcher.Match, caret: ScreenRect? = nil) {
        fieldPixelsMatch = match == .pixels
        fieldTemporalMatch = match == .temporal
        fieldAppearanceMatch = match == .appearance
        caretRect = match == .temporal ? caret : nil
    }
}

// Compare the complete field at native resolution, without OCR, color-specific
// caret detection or resampling. Keep a strict fast path, then bounded local
// appearance comparison; temporal caret exclusion is owned by the matcher.
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

    fileprivate func screenRect(_ rect: CGRect) -> ScreenRect {
        ScreenRect(CGRect(x: field.x + rect.minX / scale, y: field.y + rect.minY / scale,
                          width: rect.width / scale, height: rect.height / scale))
    }

    // Preserve original pixel coordinates. Low-amplitude encoding changes may
    // occur at EXISTING edges, but a new stroke in a flat area is not noise.
    // The area cap is additional protection, never the sole acceptance test.
    fileprivate func appearance(_ first: Data, _ next: Data, ignoring rect: CGRect? = nil) -> Bool {
        guard first.count == next.count else { return false }
        let limit = max(4, min(512, width * height / 1000))
        let noiseLimit = max(4, min(32, width * height / 16384))
        return first.withUnsafeBytes { (a: UnsafeRawBufferPointer) in
            next.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                var changed = 0, noise = Set<Int>()
                for pixel in 0..<(width * height) {
                    let x = pixel % width, y = pixel / width
                    if let rect, rect.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) { continue }
                    let i = pixel * 3
                    let delta = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])),
                                    abs(Int(a[i + 2]) - Int(b[i + 2])))
                    if delta <= ScreenGuard.pixelTolerance { continue }
                    changed += 1
                    guard delta <= 32, changed <= limit else { return false }
                    // Both images must contain contrast in the same channel at
                    // this exact location. No translation or nearest-pixel match.
                    var edge = false
                    if x >= 2, y >= 2, x + 2 < width, y + 2 < height {
                        for channel in 0..<3 {
                            var loA = 255, hiA = 0, loB = 255, hiB = 0
                            for dy in -2...2 { for dx in -2...2 {
                                let q = ((y + dy) * width + x + dx) * 3 + channel
                                loA = min(loA, Int(a[q])); hiA = max(hiA, Int(a[q]))
                                loB = min(loB, Int(b[q])); hiB = max(hiB, Int(b[q]))
                            } }
                            if min(hiA - loA, hiB - loB) >= max(24, delta * 2) { edge = true; break }
                        }
                    }
                    if !edge {
                        guard delta <= 16, noise.count < noiseLimit else { return false }
                        noise.insert(pixel)
                    }
                }
                // Residual low-contrast blocks may be at most 2x2 native
                // pixels. A connected new line is not a collection of noise.
                while let seed = noise.first {
                    noise.remove(seed)
                    var pending = [seed], minX = seed % width, maxX = minX
                    var minY = seed / width, maxY = minY
                    while let pixel = pending.popLast() {
                        let x = pixel % width, y = pixel / width
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                        guard maxX - minX < 2, maxY - minY < 2 else { return false }
                        for dy in -1...1 { for dx in -1...1 {
                            guard (0..<width).contains(x + dx), (0..<height).contains(y + dy) else { continue }
                            let next = (y + dy) * width + x + dx
                            if noise.remove(next) != nil { pending.append(next) }
                        } }
                    }
                }
                return true
            }
        }
    }

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
// A temporal exception requires an observed A-B-A cycle at one fixed narrow
// stroke. Only that stroke is excluded; the rest of the original field retains
// its local edge/content comparison. Never reconstruct or replace the baseline.
final class NativeTextPhaseMatcher {
    enum Match { case none, pixels, appearance, temporal }
    private let field: NativeTextFieldGuard
    private var frames: [Data] = []
    private var lastPNG: Data?
    private var lastMatch: Match = .none
    private(set) var caretRect: ScreenRect?

    init(field: NativeTextFieldGuard) { self.field = field }

    func check(png: Data, context: ScreenContext) throws -> Match {
        let current = try field.pixels(png: png, context: context)
        if png == lastPNG { return lastMatch } // outer preflight rechecks the selected actual PNG
        defer { lastPNG = png }
        caretRect = nil
        if field.same(field.source, current) { lastMatch = .pixels; return lastMatch }
        if field.appearance(field.source, current) { lastMatch = .appearance; return lastMatch }
        if frames.count >= 2 {
            for i in 0..<(frames.count - 1) where field.appearance(frames[i], current) {
                for j in (i + 1)..<frames.count {
                    if let rect = caret(first: frames[i], other: frames[j]),
                       field.appearance(field.source, current, ignoring: rect),
                       sourceFitsCaret(first: frames[i], other: frames[j], rect: rect) {
                        caretRect = field.screenRect(rect)
                        lastMatch = .temporal
                        return lastMatch
                    }
                }
            }
        }
        if frames.count < 6 { frames.append(current) }
        lastMatch = .none
        return lastMatch
    }

    private func caret(first: Data, other: Data) -> CGRect? {
        let a = [UInt8](first), b = [UInt8](other)
        var minX = field.width, maxX = -1, minY = field.height, maxY = -1, changed = 0
        var direction: [Int]?
        var commonDirection = true
        for pixel in 0..<(field.width * field.height) {
            let i = pixel * 3
            let delta = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])), abs(Int(a[i + 2]) - Int(b[i + 2])))
            if delta <= 16 { continue }
            let x = pixel % field.width, y = pixel / field.width
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            changed += 1
            let vector = (0..<3).map { Int(b[i + $0]) - Int(a[i + $0]) }
            if let direction {
                if zip(direction, vector).reduce(0, { $0 + $1.0 * $1.1 }) <= 0 { commonDirection = false }
            } else { direction = vector }
        }
        // A caret can blend over different background pixels. Its RGB direction
        // need not agree across the stroke, but each pixel must follow its own
        // source-relative color ray with the same fade ordering. A translated
        // stroke gains contrast at one edge and loses it at the other.
        guard commonDirection || sourceRelativeFade(first: a, other: b) else { return nil }
        let w = maxX - minX + 1, h = maxY - minY + 1
        guard changed >= 12, w > 0, h > 0,
              Double(w) <= 4 * field.scale, Double(h) >= 8 * field.scale,
              Double(h) <= 80 * field.scale, h >= 3 * w,
              Double(changed) / Double(w * h) >= 0.3 else { return nil }
        // Fixed two-native-pixel antialias/chroma rim, never expanded on retry.
        let rect = CGRect(x: minX, y: minY, width: w, height: h).insetBy(dx: -2, dy: -2)
            .intersection(CGRect(x: 0, y: 0, width: field.width, height: field.height))
        guard rect.width <= 4 * field.scale + 4,
              field.appearance(first, other, ignoring: rect) else { return nil }
        return rect
    }

    private func sourceRelativeFade(first: [UInt8], other: [UInt8]) -> Bool {
        let source = [UInt8](field.source)
        var ordering: Bool?
        for pixel in 0..<(field.width * field.height) {
            let i = pixel * 3
            let delta = (0..<3).map { abs(Int(first[i + $0]) - Int(other[i + $0])) }.max()!
            if delta <= 16 { continue }
            let a = (0..<3).map { Double(Int(first[i + $0]) - Int(source[i + $0])) }
            let b = (0..<3).map { Double(Int(other[i + $0]) - Int(source[i + $0])) }
            let aa = a.reduce(0) { $0 + $1 * $1 }, bb = b.reduce(0) { $0 + $1 * $1 }
            guard aa != bb else { return false }
            let increasing = bb > aa
            if let ordering, ordering != increasing { return false }
            ordering = increasing
            // Project the shorter vector onto the longer one. The original
            // pixel tolerance permits rounding, not a new color/area budget.
            let longer = increasing ? b : a, shorter = increasing ? a : b
            let norm = max(aa, bb)
            let factor = zip(longer, shorter).reduce(0) { $0 + $1.0 * $1.1 } / norm
            guard factor >= 0, factor <= 1,
                  zip(longer, shorter).allSatisfy({ abs($0.1 - factor * $0.0) <= Double(ScreenGuard.pixelTolerance) }) else { return false }
        }
        return ordering != nil
    }

    private func sourceFitsCaret(first: Data, other: Data, rect: CGRect) -> Bool {
        // A source selection or unrelated mark must not vanish merely because
        // it intersects the mask. Each source channel must belong to the
        // observed fade/background range; no single alpha is imposed.
        let a = [UInt8](first), b = [UInt8](other), source = [UInt8](field.source)
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let i = (y * field.width + x) * 3
                for channel in 0..<3 {
                    var lo = min(Int(a[i + channel]), Int(b[i + channel]))
                    var hi = max(Int(a[i + channel]), Int(b[i + channel]))
                    // The fixed rim supplies the local background
                    // for a hidden source phase not sampled at its exact opacity.
                    for edgeX in [Int(rect.minX), Int(rect.maxX) - 1] {
                        let q = (y * field.width + edgeX) * 3 + channel
                        lo = min(lo, min(Int(a[q]), Int(b[q])))
                        hi = max(hi, max(Int(a[q]), Int(b[q])))
                    }
                    guard (lo - 16...hi + 16).contains(Int(source[i + channel])) else { return false }
                }
            }
        }
        return true
    }
}
