import Foundation
import CoreGraphics
import ImageIO

// Shared, bounded device facts and comparison code. No refs, AX lookup, cache or recovery policy.
public struct ScreenRect: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case originX = "x", originY = "y", width, height
    }

    public let originX: Double
    public let originY: Double
    public let width: Double
    public let height: Double

    public init(_ rect: CGRect) {
        originX = rect.minX; originY = rect.minY; width = rect.width; height = rect.height
    }
    public var cgRect: CGRect { CGRect(x: originX, y: originY, width: width, height: height) }
    public var valid: Bool {
        [originX, originY, width, height, originX + width, originY + height].allSatisfy(\.isFinite)
            && width > 0
            && height > 0
    }

    public func matches(_ other: ScreenRect) -> Bool {
        zip([originX, originY, width, height], [other.originX, other.originY, other.width, other.height])
            .allSatisfy {
                abs($0 - $1) <= 0.5
            }
    }
}

public struct ScreenContext: Codable {
    public let screen: ScreenRect
    public let scope: ScreenRect
    public let orientation: Int
    public let keyboardCount: Int

    public init(screen: ScreenRect, scope: ScreenRect, orientation: Int, keyboardCount: Int) {
        self.screen = screen; self.scope = scope
        self.orientation = orientation; self.keyboardCount = keyboardCount
    }

    public var valid: Bool {
        screen.valid && scope.valid && screen.originX == 0 && screen.originY == 0
            && screen.cgRect.contains(scope.cgRect)
            && (0...6).contains(orientation) && keyboardCount >= 0
    }

    public func matches(_ other: ScreenContext) -> Bool {
        valid && other.valid && screen.matches(other.screen) && scope.matches(other.scope)
            && orientation == other.orientation && keyboardCount == other.keyboardCount
    }
}
