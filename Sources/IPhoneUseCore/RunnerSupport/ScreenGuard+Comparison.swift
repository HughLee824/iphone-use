import Foundation
import CoreGraphics
import ImageIO

extension ScreenGuard {

    // One explicitly selected animation rectangle, never inferred from differences.
    // Its geometry is observation-bound and cannot consume an action/context region.
    static func unmaskedRects(screen: ScreenRect, ignored: ScreenRect, protected: [ScreenRect]) throws
        -> [ScreenRect] {
        guard ignored.valid, screen.cgRect.contains(ignored.cgRect),
            ignored.width * ignored.height <= screen.width * screen.height * 0.25,
            protected.allSatisfy({ !$0.cgRect.intersects(ignored.cgRect) })
        else { throw Failure.invalidGuard }
        let screenBounds = screen.cgRect, region = ignored.cgRect
        return [
            CGRect(
                x: screenBounds.minX, y: screenBounds.minY, width: screenBounds.width,
                height: region.minY - screenBounds.minY),
            CGRect(
                x: screenBounds.minX, y: region.maxY, width: screenBounds.width,
                height: screenBounds.maxY - region.maxY
            ),
            CGRect(
                x: screenBounds.minX, y: region.minY, width: region.minX - screenBounds.minX,
                height: region.height),
            CGRect(
                x: region.maxX, y: region.minY, width: screenBounds.maxX - region.maxX, height: region.height)
        ]
        .filter { $0.width > 0 && $0.height > 0 }.map(ScreenRect.init)
    }

    static func bandGrid(_ rect: ScreenRect, screen: ScreenRect) -> (columns: Int, rows: Int) {
        (
            max(1, Int(ceil(Double(globalColumns) * rect.width / screen.width))),
            max(1, Int(ceil(Double(globalRows) * rect.height / screen.height)))
        )
    }

    func check(png: Data, context current: ScreenContext) throws -> Check {
        try check(image: ScreenImage(png: png), context: current)
    }

    func check(image: ScreenImage, context current: ScreenContext) throws -> Check {
        try validate()
        guard context.matches(current) else { throw Failure.contextChanged }
        guard image.image.width == pixelWidth, image.image.height == pixelHeight else {
            throw Failure.contextChanged
        }
        try image.validateMapping(to: current.screen)
        let global = try image.rgb(
            rect: context.screen, screen: context.screen, columns: Self.globalColumns, rows: Self.globalRows)
        let raw = Self.changedFraction(globalRGB, global)
        if let dynamicOverlay {
            // Diagnostic only for this explicit scope; do not report an unchecked
            // moving background as zero change.
            return Check(
                screenChange: raw, regionChanges: [], policy: policy,
                dynamicMatches: try dynamicOverlay.map {
                    try $0.matches(image: image, screen: context.screen)
                })
        }
        let changes = try regions.map { region in
            Self.changedFraction(
                region.rgb,
                try image.rgb(
                    rect: region.rect, screen: context.screen, columns: Self.regionSide, rows: Self.regionSide
                ))
        }
        guard let ignoredRect, let unmaskedRGB else {
            return Check(screenChange: raw, regionChanges: changes, policy: policy)
        }
        let rects = try Self.unmaskedRects(
            screen: context.screen, ignored: ignoredRect, protected: regions.map(\.rect))
        // Crop each static band BEFORE reducing it. Average every native pixel
        // in each grid cell: interpolation can magnify a one-pixel video rim
        // into an entire changed cell. The exclusion geometry stays exact.
        var changedArea = 0.0, area = 0.0
        for (rect, rgb) in zip(rects, unmaskedRGB) {
            let grid = Self.bandGrid(rect, screen: context.screen)
            let current = try image.areaRGB(
                rect: rect, screen: context.screen, columns: grid.columns, rows: grid.rows)
            let size = rect.width * rect.height
            changedArea += Self.changedFraction(rgb, current) * size
            area += size
        }
        return Check(
            screenChange: changedArea / area, regionChanges: changes, policy: policy,
            ignoredRect: ignoredRect, rawScreenChange: raw)
    }

    // Fraction of grid cells with at least one RGB channel differing by more than the noise floor.
    private static func changedFraction(_ lhs: Data, _ rhs: Data) -> Double {
        let firstSample = [UInt8](lhs), secondSample = [UInt8](rhs)
        var changed = 0
        for index in stride(from: 0, to: firstSample.count, by: 3)
        where (0..<3).contains(where: {
            abs(Int(firstSample[index + $0]) - Int(secondSample[index + $0])) > pixelTolerance
        }) {
            changed += 1
        }
        return Double(changed) / Double(firstSample.count / 3)
    }

    func validate() throws {
        guard
            algorithm
                == (dynamicOverlay == nil
                    ? (ignoredRect == nil ? Self.algorithm : Self.maskedAlgorithm) : Self.dynamicAlgorithm),
            context.valid, policy.valid, pixelWidth > 0, pixelHeight > 0,
            globalRGB.count == Self.globalColumns * Self.globalRows * 3,
            (1...Self.maximumRegions).contains(regions.count),
            regions.allSatisfy({
                $0.rect.valid && context.screen.cgRect.contains($0.rect.cgRect)
                    && $0.rgb.count == Self.regionSide * Self.regionSide * 3
            })
        else { throw Failure.invalidGuard }
        if let dynamicOverlay {
            guard dynamicOverlay.count == 2, ignoredRect == nil, unmaskedRGB == nil,
                policy.maxScreenChange == 0.01, policy.maxRegionChange == 0,
                dynamicOverlay.allSatisfy({
                    $0.valid && context.scope.cgRect.contains($0.rect.cgRect)
                        && $0.rect.width <= 256 && $0.rect.height <= 96
                }),
                dynamicOverlay[0].rect.width <= 96,
                !dynamicOverlay[0].rect.cgRect.intersects(dynamicOverlay[1].rect.cgRect)
            else { throw Failure.invalidGuard }
        }
        if let ignoredRect {
            let rects = try Self.unmaskedRects(
                screen: context.screen, ignored: ignoredRect, protected: regions.map(\.rect))
            guard let unmaskedRGB, unmaskedRGB.count == rects.count,
                zip(rects, unmaskedRGB).allSatisfy({ rect, rgb in
                    let size = Self.bandGrid(rect, screen: context.screen)
                    return rgb.count == size.columns * size.rows * 3
                })
            else { throw Failure.invalidGuard }
        } else if unmaskedRGB != nil {
            throw Failure.invalidGuard
        }
    }
}
