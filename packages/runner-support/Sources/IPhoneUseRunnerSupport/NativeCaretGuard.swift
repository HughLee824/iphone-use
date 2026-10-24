import Foundation
import CoreGraphics

// An optional, source-anchored exception for a single blue, yellow or green UIKit-style caret.
// Never infer a caret from a difference alone: a hidden source has no anchor.
// This is pixel evidence, not independent confirmation of editor focus.
public struct NativeCaretGuard {
    private let context: ScreenContext
    private let field: ScreenRect
    private let width: Int
    private let height: Int
    private let source: [UInt8]
    private let background: [Int]
    private let bounds: CGRect
    private let reference: Int
    private let referenceChannel: Int
    private let allowsAdjacentText: Bool
    public let caret: ScreenRect

    public init?(
        png: Data, context: ScreenContext, field: ScreenRect, allowsAdjacentText: Bool = false,
        allowsColoredCarets: Bool = true
    ) throws {
        guard context.valid, field.valid, context.screen.cgRect.contains(field.cgRect) else { return nil }
        let image = try ScreenImage(png: png)
        try image.validateMapping(to: context.screen)
        let scale = Double(image.image.width) / context.screen.width
        let crop = CGRect(
            x: field.originX * scale, y: field.originY * scale, width: field.width * scale,
            height: field.height * scale
        ).integral
        let width = Int(crop.width), height = Int(crop.height)
        guard width > 0, height > 0, width * height <= 4_000_000 else { return nil }
        let source = [UInt8](try image.rgb(rect: field, screen: context.screen, columns: width, rows: height))
        let detected = Self.colorMask(
            source, width: width, height: height, allowsColoredCarets: allowsColoredCarets)
        let component: Component
        if allowsColoredCarets {
            guard
                let candidate = Self.uniqueCandidate(
                    mask: detected.mask, width: width, height: height, scale: scale)
            else { return nil }
            component = candidate
        } else {
            component = detected.component
        }
        let left = component.left, right = component.right, top = component.top, bottom = component.bottom
        let count = component.count
        let pixelWidth = right - left + 1, pixelHeight = bottom - top + 1
        guard count > 0, Double(pixelWidth) >= scale, Double(pixelWidth) <= 3 * scale,
            Double(pixelHeight) >= 8 * scale, Double(pixelHeight) <= 40 * scale,
            Double(count) / Double(pixelWidth * pixelHeight) >= 0.85,
            left >= 3, top >= 3, right + 3 < width, bottom + 3 < height
        else { return nil }
        guard
            let model = Self.fadeModel(
                source: source, width: width, component: component, allowsAdjacentText: allowsAdjacentText
            )
        else { return nil }
        self.context = context; self.field = field; self.width = width; self.height = height
        self.source = source; self.background = model.background; self.bounds = model.bounds
        self.reference = model.reference
        self.referenceChannel = model.channel
        self.allowsAdjacentText = allowsAdjacentText
        caret = ScreenRect(
            CGRect(
                x: (crop.minX + Double(left)) / scale, y: (crop.minY + Double(top)) / scale,
                width: Double(pixelWidth) / scale, height: Double(pixelHeight) / scale))
    }

    public func acceptsBlink(png: Data, context current: ScreenContext) throws -> Bool {
        guard context.matches(current) else { return false }
        let image = try ScreenImage(png: png)
        try image.validateMapping(to: current.screen)
        let scale = Double(image.image.width) / current.screen.width
        let crop = CGRect(
            x: field.originX * scale, y: field.originY * scale, width: field.width * scale,
            height: field.height * scale
        ).integral
        guard Int(crop.width) == width, Int(crop.height) == height else { return false }
        let next = [UInt8](try image.rgb(rect: field, screen: current.screen, columns: width, rows: height))
        let factor =
            Double(Int(next[reference + referenceChannel]) - background[referenceChannel])
            / Double(Int(source[reference + referenceChannel]) - background[referenceChannel])
        guard factor >= 0, factor <= 6 else { return false }
        return source.withUnsafeBufferPointer { source in
            next.withUnsafeBufferPointer { next in
                matchesFade(source: source, next: next, factor: factor)
            }
        }
    }

    private func matchesFade(
        source: UnsafeBufferPointer<UInt8>, next: UnsafeBufferPointer<UInt8>, factor: Double
    )
        -> Bool {
        for row in 0..<height {
            let rowOffset = row * width * 3
            let caretRow = Double(row) >= bounds.minY && Double(row) < bounds.maxY
            if !caretRow,
                memcmp(
                    source.baseAddress!.advanced(by: rowOffset), next.baseAddress!.advanced(by: rowOffset),
                    width * 3)
                    == 0 {
                continue
            }
            for column in 0..<width {
                let index = rowOffset + column * 3
                let inside = caretRow && Double(column) >= bounds.minX && Double(column) < bounds.maxX
                if !inside, source[index] == next[index], source[index + 1] == next[index + 1],
                    source[index + 2] == next[index + 2] {
                    continue
                }
                for channel in 0..<3 {
                    let expected =
                        inside
                        ? Double(background[channel]) + Double(
                            Int(source[index + channel]) - background[channel])
                            * factor
                        : Double(source[index + channel])
                    if abs(Double(next[index + channel]) - expected) > Double(ScreenGuard.pixelTolerance) {
                        guard inside, acceptsAntialiasedEdge(x: column, y: row, source: source, next: next)
                        else {
                            return false
                        }
                        break
                    }
                }
            }
        }
        return true
    }

    // Post-input only: a glyph can overlap the outermost caret pixel. Its
    // antialiasing no longer fades against the uniform background. Require a
    // stationary neutral text edge immediately outside the stroke, and bound
    // every channel's movement by the measured caret phase. No extra pixels
    // outside the original stroke are masked; native input admission stays strict.
    private func acceptsAntialiasedEdge(
        x column: Int, y row: Int, source: UnsafeBufferPointer<UInt8>, next: UnsafeBufferPointer<UInt8>
    ) -> Bool {
        guard allowsAdjacentText,
            column == Int(bounds.minX) || column == Int(bounds.maxX) - 1 || row == Int(bounds.minY)
                || row == Int(bounds.maxY) - 1
        else { return false }
        let index = (row * width + column) * 3
        for channel in 0..<3 {
            let phase = Int(next[reference + channel]) - Int(source[reference + channel])
            let delta = Int(next[index + channel]) - Int(source[index + channel])
            guard abs(delta) <= abs(phase) + ScreenGuard.pixelTolerance,
                phase >= 0 ? delta >= -ScreenGuard.pixelTolerance : delta <= ScreenGuard.pixelTolerance
            else { return false }
        }
        func luminance(_ pixel: Int, _ data: UnsafeBufferPointer<UInt8>) -> Double {
            0.299 * Double(data[pixel]) + 0.587 * Double(data[pixel + 1]) + 0.114 * Double(data[pixel + 2])
        }
        let backgroundColor =
            0.299 * Double(background[0]) + 0.587 * Double(background[1]) + 0.114 * Double(background[2])
        for neighborY in (row - 1)...(row + 1) {
            for neighborX in (column - 1)...(column + 1) {
                guard !bounds.contains(CGPoint(x: neighborX, y: neighborY)) else { continue }
                let neighbor = (neighborY * width + neighborX) * 3
                let colors = (0..<3).map { Int(source[neighbor + $0]) }
                guard colors.max()! - colors.min()! <= ScreenGuard.pixelTolerance,
                    (0..<3).allSatisfy({ source[neighbor + $0] == next[neighbor + $0] })
                else { continue }
                let edge = luminance(neighbor, source)
                guard abs(edge - backgroundColor) >= 40 else { continue }
                let range = min(backgroundColor, edge)...max(backgroundColor, edge)
                if range.contains(luminance(index, source)), range.contains(luminance(index, next)) {
                    return true
                }
            }
        }
        return false
    }
}

extension NativeCaretGuard {
    private struct Component {
        var left: Int
        var right = -1
        var top: Int
        var bottom = -1
        var count = 0

        mutating func include(column: Int, row: Int) {
            left = min(left, column); right = max(right, column)
            top = min(top, row); bottom = max(bottom, row); count += 1
        }

        func isCaret(scale: Double) -> Bool {
            let width = right - left + 1, height = bottom - top + 1
            return Double(width) >= scale && Double(width) <= 3 * scale
                && Double(height) >= 8 * scale && Double(height) <= 40 * scale
                && Double(count) / Double(width * height) >= 0.85
        }
    }

    private static func isCaretColor(_ source: [UInt8], index: Int, allowsColoredCarets: Bool) -> Bool {
        let redValue = Int(source[index]), greenValue = Int(source[index + 1]),
            blueValue = Int(source[index + 2])
        let blue = blueValue >= 70 && blueValue - redValue >= 30 && blueValue - greenValue >= 15
        let yellow =
            allowsColoredCarets && redValue >= 120 && greenValue >= 100 && redValue - blueValue >= 60
            && greenValue - blueValue >= 45 && abs(redValue - greenValue) <= 100
        let green =
            allowsColoredCarets && greenValue >= 70 && greenValue - redValue >= 30
            && greenValue - blueValue >= 15
        return blue || yellow || green
    }

    private static func colorMask(_ source: [UInt8], width: Int, height: Int, allowsColoredCarets: Bool)
        -> (mask: [UInt8], component: Component) {
        var mask = [UInt8](repeating: 0, count: width * height)
        var component = Component(left: width, top: height)
        for row in 0..<height {
            for column in 0..<width {
                let index = (row * width + column) * 3
                if isCaretColor(source, index: index, allowsColoredCarets: allowsColoredCarets) {
                    mask[row * width + column] = 1
                    component.include(column: column, row: row)
                }
            }
        }
        return (mask, component)
    }

    private static func uniqueCandidate(mask: [UInt8], width: Int, height: Int, scale: Double) -> Component? {
        var mask = mask
        var candidate: Component?
        for seed in mask.indices where mask[seed] == 1 {
            let component = connectedComponent(seed: seed, mask: &mask, width: width, height: height)
            if component.isCaret(scale: scale) {
                guard candidate == nil else { return nil }
                candidate = component
            }
        }
        return candidate
    }

    private static func connectedComponent(seed: Int, mask: inout [UInt8], width: Int, height: Int)
        -> Component {
        var pending = [seed]
        mask[seed] = 0
        var component = Component(left: width, top: height)
        while let pixel = pending.popLast() {
            let column = pixel % width, row = pixel / width
            component.include(column: column, row: row)
            for neighborY in max(0, row - 1)...min(height - 1, row + 1) {
                for neighborX in max(0, column - 1)...min(width - 1, column + 1) {
                    let neighbor = neighborY * width + neighborX
                    if mask[neighbor] == 1 { mask[neighbor] = 0; pending.append(neighbor) }
                }
            }
        }
        return component
    }

    private struct FadeModel {
        let background: [Int]
        let bounds: CGRect
        let reference: Int
        let channel: Int
    }

    private static func fadeModel(source: [UInt8], width: Int, component: Component, allowsAdjacentText: Bool)
        -> FadeModel? {
        let left = component.left, right = component.right, top = component.top, bottom = component.bottom
        let pixelWidth = right - left + 1, pixelHeight = bottom - top + 1
        // One antialiasing pixel around the detected stroke. The next surrounding
        // ring must be uniform, so adjacent text/selection handles cannot be erased.
        // Post-input stability can keep adjacent glyphs: restrict the fade model to
        // the detected stroke itself. Input admission retains its stricter ring.
        let bounds =
            allowsAdjacentText
            ? CGRect(x: left, y: top, width: pixelWidth, height: pixelHeight)
            : CGRect(x: left - 1, y: top - 1, width: pixelWidth + 2, height: pixelHeight + 2)
        let bgIndex = ((top - 2) * width + (allowsAdjacentText ? (left + right) / 2 : left - 2)) * 3
        let background = (0..<3).map { Int(source[bgIndex + $0]) }
        for row in (top - 2)...(bottom + 2) {
            for column in (left - 2)...(right + 2) {
                if allowsAdjacentText || bounds.contains(CGPoint(x: column, y: row)) { continue }
                let index = (row * width + column) * 3
                guard
                    (0..<3).allSatisfy({
                        abs(Int(source[index + $0]) - background[$0]) <= ScreenGuard.pixelTolerance
                    })
                else { return nil }
            }
        }
        // Use the strongest color contrast to estimate a single fade factor. The
        // entire stroke must fit that factor; a changed shape is not a blink.
        var reference = (top * width + left) * 3, referenceChannel = 0, contrast = 0
        for row in top...bottom {
            for column in left...right {
                let index = (row * width + column) * 3
                for channel in 0..<3 {
                    let value = abs(Int(source[index + channel]) - background[channel])
                    if value > contrast { contrast = value; reference = index; referenceChannel = channel }
                }
            }
        }
        guard contrast >= 40 else { return nil }
        return FadeModel(
            background: background, bounds: bounds, reference: reference, channel: referenceChannel)
    }
}
