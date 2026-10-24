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
        guard context.valid, field.valid, context.screen.cgRect.contains(field.cgRect) else {
            throw ScreenGuard.Failure.invalidGuard
        }
        let image = try ScreenImage(png: png)
        try image.validateMapping(to: context.screen)
        let scale = Double(image.image.width) / context.screen.width
        let crop = CGRect(
            x: field.originX * scale, y: field.originY * scale, width: field.width * scale,
            height: field.height * scale
        ).integral
        width = Int(crop.width); height = Int(crop.height)
        guard width > 0, height > 0, width * height <= 4_000_000 else {
            throw ScreenGuard.Failure.invalidGuard
        }
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
    func screenComparisonImage(
        _ image: ScreenImage, caret: NativeBoundCaretGuard,
        context current: ScreenContext
    ) throws -> ScreenImage {
        try validateContext(current)
        try image.validateMapping(to: current.screen)
        let rect = caret.bounds
        let column = Int(crop.minX + rect.minX), firstRow = Int(crop.minY + rect.minY)
        let columns = image.image.width, rows = image.image.height
        guard column >= 0, firstRow >= 0, column + Int(rect.width) <= columns,
            firstRow + Int(rect.height) <= rows
        else {
            throw ScreenGuard.Failure.invalidGuard
        }
        var rgb = try image.rgb(rect: current.screen, screen: current.screen, columns: columns, rows: rows)
        for row in 0..<Int(rect.height) {
            let sourceOffset = ((Int(rect.minY) + row) * width + Int(rect.minX)) * 3
            let targetOffset = ((firstRow + row) * columns + column) * 3
            let count = Int(rect.width) * 3
            rgb.replaceSubrange(
                targetOffset..<(targetOffset + count),
                with: source[sourceOffset..<(sourceOffset + count)])
        }
        guard let provider = CGDataProvider(data: rgb as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let result = CGImage(
                width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 24,
                bytesPerRow: columns * 3, space: colorSpace, bitmapInfo: [], provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else {
            throw ScreenGuard.Failure.invalidImage
        }
        return ScreenImage(image: result)
    }

    func matches(png: Data, context current: ScreenContext) throws -> Bool {
        same(source, try pixels(png: png, context: current))
    }

    func screenRect(_ rect: CGRect) -> ScreenRect {
        ScreenRect(
            CGRect(
                x: (crop.minX + rect.minX) / scale, y: (crop.minY + rect.minY) / scale,
                width: rect.width / scale, height: rect.height / scale))
    }

    // Preserve original pixel coordinates. Low-amplitude encoding changes may
    // occur at EXISTING edges, but a new stroke in a flat area is not noise.
    // The area cap is additional protection, never the sole acceptance test.
    func appearance(_ first: Data, _ next: Data, ignoring rect: CGRect? = nil) -> Bool {
        guard first.count == next.count else { return false }
        let limit = max(4, min(512, width * height / 1000))
        let noiseLimit = max(4, min(32, width * height / 16384))
        return first.withUnsafeBytes { (firstSample: UnsafeRawBufferPointer) in
            next.withUnsafeBytes { (secondSample: UnsafeRawBufferPointer) in
                var changed = 0, noise = Set<Int>()
                for pixel in 0..<(width * height) {
                    let column = pixel % width, row = pixel / width
                    if let rect, rect.contains(CGPoint(x: Double(column) + 0.5, y: Double(row) + 0.5)) {
                        continue
                    }
                    let index = pixel * 3
                    let delta = max(
                        abs(Int(firstSample[index]) - Int(secondSample[index])),
                        abs(Int(firstSample[index + 1]) - Int(secondSample[index + 1])),
                        abs(Int(firstSample[index + 2]) - Int(secondSample[index + 2])))
                    if delta <= ScreenGuard.pixelTolerance { continue }
                    changed += 1
                    guard delta <= 32, changed <= limit else { return false }
                    // Both images must contain contrast in the same channel at
                    // this exact location. No translation or nearest-pixel match.
                    let edge = hasSharedEdge(firstSample, secondSample, pixel: pixel, delta: delta)
                    if !edge {
                        guard delta <= 16, noise.count < noiseLimit else { return false }
                        noise.insert(pixel)
                    }
                }
                return hasBoundedNoise(noise)
            }
        }
    }

    private func hasSharedEdge(
        _ firstSample: UnsafeRawBufferPointer, _ secondSample: UnsafeRawBufferPointer,
        pixel: Int, delta: Int
    ) -> Bool {
        let column = pixel % width, row = pixel / width

        if column >= 2, row >= 2, column + 2 < width, row + 2 < height {
            for channel in 0..<3 {
                var loA = 255, hiA = 0, loB = 255, hiB = 0
                for offsetY in -2...2 {
                    for offsetX in -2...2 {
                        let neighborIndex = ((row + offsetY) * width + column + offsetX) * 3 + channel
                        loA = min(loA, Int(firstSample[neighborIndex]))
                        hiA = max(hiA, Int(firstSample[neighborIndex]))
                        loB = min(loB, Int(secondSample[neighborIndex]))
                        hiB = max(hiB, Int(secondSample[neighborIndex]))
                    }
                }
                if min(hiA - loA, hiB - loB) >= max(24, delta * 2) { return true }
            }
        }
        return false
    }

    private func hasBoundedNoise(_ pixels: Set<Int>) -> Bool {
        var noise = pixels
        // Residual low-contrast blocks may be at most 2x2 native
        // pixels. A connected new line is not a collection of noise.
        while let seed = noise.first {
            noise.remove(seed)
            var pending = [seed], minX = seed % width, maxX = minX
            var minY = seed / width, maxY = minY
            while let pixel = pending.popLast() {
                let column = pixel % width, row = pixel / width
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
                guard maxX - minX < 2, maxY - minY < 2 else { return false }
                for offsetY in -1...1 {
                    for offsetX in -1...1 {
                        guard (0..<width).contains(column + offsetX), (0..<height).contains(row + offsetY)
                        else { continue }
                        let next = (row + offsetY) * width + column + offsetX
                        if noise.remove(next) != nil { pending.append(next) }
                    }
                }
            }
        }
        return true
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
        source.withUnsafeBytes { (firstSample: UnsafeRawBufferPointer) in
            current.withUnsafeBytes { (secondSample: UnsafeRawBufferPointer) in
                for pointer in 0..<(width * height) {
                    let index = pointer * 3
                    if (0..<3).map({ abs(Int(firstSample[index + $0]) - Int(secondSample[index + $0])) })
                        .max()! <= 16 {
                        continue
                    }
                    left = min(left, pointer % width); right = max(right, pointer % width)
                    top = min(top, pointer / width); bottom = max(bottom, pointer / width); count += 1
                }
            }
        }
        let pixelWidth = right - left + 1, pixelHeight = bottom - top + 1
        // A candidate is a reason to ask for visual confirmation, never a mask.
        return count >= 12 && pixelWidth > 0 && Double(pixelWidth) <= 4 * scale
            && Double(pixelHeight) >= 8 * scale
            && Double(pixelHeight) <= 80 * scale && pixelHeight >= pixelWidth * 3
            ? "caret_confirmation_required" : "text_field_changed"
    }

    func nativeRect(_ rect: ScreenRect) throws -> CGRect {
        guard rect.valid, field.cgRect.contains(rect.cgRect), rect.width <= 4,
            (8...80).contains(rect.height), rect.height >= rect.width * 3
        else {
            throw IPhoneUseError(
                "invalid_caret_region",
                """
                Confirm one narrow vertical caret inside the complete field (width <=4, height 8...80 screen\
                 points)
                """)
        }
        return CGRect(
            x: rect.originX * scale - crop.minX, y: rect.originY * scale - crop.minY,
            width: rect.width * scale, height: rect.height * scale
        ).integral
    }

    func same(_ first: Data, _ next: Data) -> Bool {
        guard first.count == next.count else { return false }
        return first.withUnsafeBytes { (firstSample: UnsafeRawBufferPointer) in
            next.withUnsafeBytes { (secondSample: UnsafeRawBufferPointer) in
                var noise: [Int] = []
                for pixel in 0..<(width * height) {
                    let index = pixel * 3
                    let delta = max(
                        abs(Int(firstSample[index]) - Int(secondSample[index])),
                        abs(Int(firstSample[index + 1]) - Int(secondSample[index + 1])),
                        abs(Int(firstSample[index + 2]) - Int(secondSample[index + 2])))
                    if delta <= ScreenGuard.pixelTolerance { continue }
                    guard delta <= 16, noise.count < 4 else { return false }
                    let column = pixel % width, row = pixel / width
                    guard
                        !noise.contains(where: { abs($0 % width - column) <= 1 && abs($0 / width - row) <= 1 }
                        )
                    else {
                        return false
                    }
                    noise.append(pixel)
                }
                return true
            }
        }
    }
}
