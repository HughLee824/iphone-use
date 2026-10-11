import Foundation
import CoreGraphics

// Compare the complete field at native resolution, without OCR, color-specific
// caret detection or resampling. Keep a strict fast path, then bounded local
// appearance comparison; an Agent-confirmed caret is checked separately against the same source.
struct NativeTextFieldGuard {
    private let context: ScreenContext
    private let field: ScreenRect
    let width: Int
    let height: Int
    let source: Data
    let scale: Double
    private let crop: CGRect

    init(png: Data, context: ScreenContext, field: ScreenRect) throws {
        guard context.valid, field.valid, context.screen.cgRect.contains(field.cgRect) else { throw ScreenGuard.Failure.invalidGuard }
        let image = try ScreenImage(png: png)
        try image.validateMapping(to: context.screen)
        let scale = Double(image.image.width) / context.screen.width
        let crop = CGRect(x: field.x * scale, y: field.y * scale, width: field.width * scale, height: field.height * scale).integral
        width = Int(crop.width); height = Int(crop.height)
        guard width > 0, height > 0, width * height <= 4_000_000 else { throw ScreenGuard.Failure.invalidGuard }
        source = try image.rgb(rect: field, screen: context.screen, columns: width, rows: height)
        self.context = context; self.field = field; self.scale = scale; self.crop = crop
    }

    func validateContext(_ current: ScreenContext) throws {
        guard context.matches(current) else { throw ScreenGuard.Failure.contextChanged }
    }

    func pixels(png: Data, context current: ScreenContext, decodedImage: ScreenImage? = nil) throws -> Data {
        try validateContext(current)
        let image = try decodedImage ?? ScreenImage(png: png)
        try image.validateMapping(to: current.screen)
        return try image.rgb(rect: field, screen: current.screen, columns: width, rows: height)
    }

    // Neutralize only the confirmed native pixels before the coarse screen/region
    // grids are reduced. Otherwise interpolation can count the excluded caret in
    // the global score. The captured PNG and full-field comparison remain untouched.
    func screenComparisonImage(_ image: ScreenImage, caret: NativeBoundCaretGuard,
                               context current: ScreenContext) throws -> ScreenImage {
        try validateContext(current)
        try image.validateMapping(to: current.screen)
        let rect = caret.bounds
        let x = Int(crop.minX + rect.minX), y = Int(crop.minY + rect.minY)
        let columns = image.image.width, rows = image.image.height
        guard x >= 0, y >= 0, x + Int(rect.width) <= columns, y + Int(rect.height) <= rows else {
            throw ScreenGuard.Failure.invalidGuard
        }
        var rgb = try image.rgb(rect: current.screen, screen: current.screen, columns: columns, rows: rows)
        for row in 0..<Int(rect.height) {
            let sourceOffset = ((Int(rect.minY) + row) * width + Int(rect.minX)) * 3
            let targetOffset = ((y + row) * columns + x) * 3
            let count = Int(rect.width) * 3
            rgb.replaceSubrange(targetOffset..<(targetOffset + count),
                                with: source[sourceOffset..<(sourceOffset + count)])
        }
        guard let provider = CGDataProvider(data: rgb as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let result = CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 24,
                  bytesPerRow: columns * 3, space: colorSpace, bitmapInfo: [], provider: provider,
                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ScreenGuard.Failure.invalidImage
        }
        return ScreenImage(image: result)
    }

    func matches(png: Data, context current: ScreenContext) throws -> Bool {
        same(source, try pixels(png: png, context: current))
    }

    func screenRect(_ rect: CGRect) -> ScreenRect {
        ScreenRect(CGRect(x: (crop.minX + rect.minX) / scale, y: (crop.minY + rect.minY) / scale,
                          width: rect.width / scale, height: rect.height / scale))
    }

    // Preserve original pixel coordinates. Low-amplitude encoding changes may
    // occur at EXISTING edges, but a new stroke in a flat area is not noise.
    // The area cap is additional protection, never the sole acceptance test.
    func appearance(_ first: Data, _ next: Data, ignoring rect: CGRect? = nil) -> Bool {
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

    enum Match { case none, pixels, appearance, caret }

    func compare(_ current: Data, caret: NativeBoundCaretGuard?) -> Match {
        if same(source, current) { return .pixels }
        if appearance(source, current) { return .appearance }
        if let caret, appearance(source, current, ignoring: caret.bounds) { return .caret }
        return .none
    }

    func rejection(_ current: Data, caret: NativeBoundCaretGuard?) -> String {
        if caret != nil { return "text_field_changed" }
        var left = width, right = -1, top = height, bottom = -1, count = 0
        source.withUnsafeBytes { (a: UnsafeRawBufferPointer) in
            current.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                for p in 0..<(width * height) {
                    let i = p * 3
                    if (0..<3).map({ abs(Int(a[i + $0]) - Int(b[i + $0])) }).max()! <= 16 { continue }
                    left = min(left, p % width); right = max(right, p % width)
                    top = min(top, p / width); bottom = max(bottom, p / width); count += 1
                }
            }
        }
        let w = right - left + 1, h = bottom - top + 1
        // A candidate is a reason to ask for visual confirmation, never a mask.
        return count >= 12 && w > 0 && Double(w) <= 4 * scale && Double(h) >= 8 * scale
            && Double(h) <= 80 * scale && h >= w * 3 ? "caret_confirmation_required" : "text_field_changed"
    }

    func nativeRect(_ rect: ScreenRect) throws -> CGRect {
        guard rect.valid, field.cgRect.contains(rect.cgRect), rect.width <= 4,
              (8...80).contains(rect.height), rect.height >= rect.width * 3 else {
            throw IPhoneUseError("invalid_caret_region", "Confirm one narrow vertical caret inside the complete field (width <=4, height 8...80 screen points)")
        }
        return CGRect(x: rect.x * scale - crop.minX, y: rect.y * scale - crop.minY,
                      width: rect.width * scale, height: rect.height * scale).integral
    }

    func same(_ first: Data, _ next: Data) -> Bool {
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
