import Foundation
import CoreGraphics

// Native-media gestures only. Keep the original PNG's pixels and coordinates;
// never register/translate images, learn a new baseline, or infer an exclusion.
// The regular grid comparison remains the fast path and the global gate.
struct NativeGestureAppearanceGuard {
    private let context: ScreenContext
    private let pixelWidth: Int
    private let pixelHeight: Int
    private let regions: [Region]

    init(png: Data, guardValue: ScreenGuard) throws {
        try guardValue.validate()
        let image = try ScreenImage(png: png)
        context = guardValue.context
        pixelWidth = image.image.width; pixelHeight = image.image.height
        guard pixelWidth == guardValue.pixelWidth, pixelHeight == guardValue.pixelHeight else {
            throw ScreenGuard.Failure.contextChanged
        }
        regions = try guardValue.regions.map { try Region(image: image, rect: $0.rect, screen: guardValue.context.screen) }
    }

    func matches(png: Data, context current: ScreenContext, guardValue: ScreenGuard, check: ScreenGuard.Check) throws -> [Bool] {
        guard context.matches(current), context.matches(guardValue.context),
              regions.map(\.rect) == guardValue.regions.map(\.rect), check.regionChanges.count == regions.count else {
            throw ScreenGuard.Failure.contextChanged
        }
        let image = try ScreenImage(png: png)
        guard image.image.width == pixelWidth, image.image.height == pixelHeight else { throw ScreenGuard.Failure.contextChanged }
        return try regions.enumerated().map { index, region in
            // Do not replace a passing grid result with an unrelated test.
            guard check.regionChanges[index] > check.policy.maxRegionChange else { return false }
            let current = try image.rgb(rect: region.rect, screen: context.screen, columns: region.width, rows: region.height)
            return region.appearance(region.source, current)
        }
    }

    private struct Region {
        let rect: ScreenRect
        let width: Int
        let height: Int
        let source: Data

        init(image: ScreenImage, rect: ScreenRect, screen: ScreenRect) throws {
            self.rect = rect
            let crop = CGRect(x: rect.x * Double(image.image.width) / screen.width,
                              y: rect.y * Double(image.image.height) / screen.height,
                              width: rect.width * Double(image.image.width) / screen.width,
                              height: rect.height * Double(image.image.height) / screen.height).integral
            width = Int(crop.width); height = Int(crop.height)
            guard width > 0, height > 0, width <= 4_000_000 / height else { throw ScreenGuard.Failure.invalidGuard }
            source = try image.rgb(rect: rect, screen: screen, columns: width, rows: height)
        }

        // Engineering bounds, not semantic equivalence: <=32/channel and <=5%
        // affected pixels are backstops. Every excess pixel additionally needs
        // existing contrast at the SAME location in both images (9x9 support).
        // Flat-area residuals are <=16, <=32 pixels total, in <=2x2 components.
        // Per-16x16 signed color means retain the original 8-level noise floor.
        func appearance(_ first: Data, _ next: Data) -> Bool {
            guard first.count == next.count else { return false }
            let limit = max(4, width * height / 20)
            let noiseLimit = 32
            return first.withUnsafeBytes { (a: UnsafeRawBufferPointer) in
                next.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
                    var changed = 0, noise = Set<Int>()
                    for pixel in 0..<(width * height) {
                        let x = pixel % width, y = pixel / width
                        let i = pixel * 3
                        let delta = max(abs(Int(a[i]) - Int(b[i])), abs(Int(a[i + 1]) - Int(b[i + 1])),
                                        abs(Int(a[i + 2]) - Int(b[i + 2])))
                        if delta <= ScreenGuard.pixelTolerance { continue }
                        changed += 1
                        guard delta <= 32, changed <= limit else { return false }
                        // Both images must contain contrast in the same channel at
                        // this exact location. No translation or nearest-pixel match.
                        var edge = false
                        for channel in 0..<3 {
                            var loA = 255, hiA = 0, loB = 255, hiB = 0
                            for dy in max(-4, -y)...min(4, height - 1 - y) { for dx in max(-4, -x)...min(4, width - 1 - x) {
                                let q = ((y + dy) * width + x + dx) * 3 + channel
                                loA = min(loA, Int(a[q])); hiA = max(hiA, Int(a[q]))
                                loB = min(loB, Int(b[q])); hiB = max(hiB, Int(b[q]))
                            } }
                            if min(hiA - loA, hiB - loB) >= max(24, delta * 2) { edge = true; break }
                        }
                        if !edge {
                            guard delta <= 16, noise.count < noiseLimit else { return false }
                            noise.insert(pixel)
                        }
                    }
                    for top in stride(from: 0, to: height, by: 16) {
                        for left in stride(from: 0, to: width, by: 16) {
                            let right = min(width, left + 16), bottom = min(height, top + 16)
                            let count = (right - left) * (bottom - top)
                            for channel in 0..<3 {
                                var delta = 0
                                for y in top..<bottom { for x in left..<right {
                                    let i = (y * width + x) * 3 + channel
                                    delta += Int(a[i]) - Int(b[i])
                                } }
                                guard abs(delta) <= ScreenGuard.pixelTolerance * count else { return false }
                            }
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
    }
}
