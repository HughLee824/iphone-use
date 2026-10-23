import Foundation
import CoreGraphics
import ImageIO

// Shared, bounded device facts and comparison code. No refs, AX lookup, cache or recovery policy.
struct ScreenRect: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case originX = "x", originY = "y", width, height
    }

    let originX: Double
    let originY: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        originX = rect.minX; originY = rect.minY; width = rect.width; height = rect.height
    }
    var cgRect: CGRect { CGRect(x: originX, y: originY, width: width, height: height) }
    var valid: Bool {
        [originX, originY, width, height, originX + width, originY + height].allSatisfy(\.isFinite)
            && width > 0
            && height > 0
    }

    func matches(_ other: ScreenRect) -> Bool {
        zip([originX, originY, width, height], [other.originX, other.originY, other.width, other.height])
            .allSatisfy {
                abs($0 - $1) <= 0.5
            }
    }
}

struct ScreenContext: Codable {
    let screen: ScreenRect
    let scope: ScreenRect
    let orientation: Int
    let keyboardCount: Int

    var valid: Bool {
        screen.valid && scope.valid && screen.originX == 0 && screen.originY == 0
            && screen.cgRect.contains(scope.cgRect)
            && (0...6).contains(orientation) && keyboardCount >= 0
    }

    func matches(_ other: ScreenContext) -> Bool {
        valid && other.valid && screen.matches(other.screen) && scope.matches(other.scope)
            && orientation == other.orientation && keyboardCount == other.keyboardCount
    }
}
