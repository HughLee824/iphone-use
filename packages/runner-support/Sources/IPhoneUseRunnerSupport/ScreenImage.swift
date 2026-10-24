import Foundation
import CoreGraphics
import ImageIO

public struct ScreenImage {
    public let image: CGImage

    public init(image: CGImage) { self.image = image }

    public init(png: Data) throws {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(width, height)
                ] as CFDictionary)
        else { throw ScreenGuard.Failure.invalidImage }
        self.image = image
    }

    public func validateMapping(to screen: ScreenRect) throws {
        // Full-screen iPhone captures only; never stretch a mismatched image onto old coordinates.
        let scaleX = Double(image.width) / screen.width, scaleY = Double(image.height) / screen.height
        guard scaleX >= 1, scaleY >= 1, abs(scaleX - scaleY) <= 0.01 else {
            throw ScreenGuard.Failure.invalidImage
        }
    }

    // Deterministic box averages for the coarse, unmasked global bands only.
    // Keep native field pixels and protected-region comparison unchanged.
    public func areaRGB(rect: ScreenRect, screen: ScreenRect, columns: Int, rows: Int) throws -> Data {
        let scaleX = Double(image.width) / screen.width, scaleY = Double(image.height) / screen.height
        let pixels = CGRect(
            x: (rect.originX - screen.originX) * scaleX, y: (rect.originY - screen.originY) * scaleY,
            width: rect.width * scaleX, height: rect.height * scaleY
        ).integral
        guard let crop = image.cropping(to: pixels), columns > 0, rows > 0,
            columns <= crop.width, rows <= crop.height,
            crop.width <= 16_000_000 / crop.height
        else { throw ScreenGuard.Failure.invalidImage }
        let width = crop.width, height = crop.height
        // Render at native resolution: no interpolation before the average.
        let native = try rgb(rect: rect, screen: screen, columns: width, rows: height)
        var result = Data(count: columns * rows * 3)
        result.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) in
            native.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                for row in 0..<rows {
                    let minY = row * height / rows, maxY = (row + 1) * height / rows
                    for column in 0..<columns {
                        let minX = column * width / columns, maxX = (column + 1) * width / columns
                        var red = 0, green = 0, blue = 0
                        for originY in minY..<maxY {
                            for originX in minX..<maxX {
                                let offset = (originY * width + originX) * 3
                                red += Int(source[offset]); green += Int(source[offset + 1])
                                blue += Int(source[offset + 2])
                            }
                        }
                        let count = (maxX - minX) * (maxY - minY), offset = (row * columns + column) * 3
                        out[offset] = UInt8((red + count / 2) / count)
                        out[offset + 1] = UInt8((green + count / 2) / count)
                        out[offset + 2] = UInt8((blue + count / 2) / count)
                    }
                }
            }
        }
        return result
    }

    public func rgb(rect: ScreenRect, screen: ScreenRect, columns: Int, rows: Int) throws -> Data {
        let scaleX = Double(image.width) / screen.width, scaleY = Double(image.height) / screen.height
        let pixels = CGRect(
            x: (rect.originX - screen.originX) * scaleX, y: (rect.originY - screen.originY) * scaleY,
            width: rect.width * scaleX, height: rect.height * scaleY
        ).integral
        guard let crop = image.cropping(to: pixels), let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            throw ScreenGuard.Failure.invalidImage
        }
        var rgba = [UInt8](repeating: 0, count: columns * rows * 4)
        try rgba.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: columns, height: rows,
                    bitsPerComponent: 8, bytesPerRow: columns * 4, space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue)
            else {
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
