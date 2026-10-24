import Foundation
import CoreGraphics
import ImageIO

public struct SwipeMotion: Codable, Equatable {
    public static let maximumEstimatedDuration: TimeInterval = 10
    public var velocity = 500.0
    public var pressDuration = 0.0
    public var holdDuration = 0.0

    public init(velocity: Double = 500, pressDuration: Double = 0, holdDuration: Double = 0) {
        self.velocity = velocity; self.pressDuration = pressDuration; self.holdDuration = holdDuration
    }

    public var valid: Bool {
        [velocity, pressDuration, holdDuration].allSatisfy(\.isFinite)
            && velocity > 0 && velocity <= 10_000
            && (0...5).contains(pressDuration) && (0...5).contains(holdDuration)
    }

    public var result: [String: Any] {
        ["velocity": velocity, "pressDuration": pressDuration, "holdDuration": holdDuration]
    }
}

// Distances are the separation of two fingers along the current screenshot's X axis.
// They describe input geometry, not the scale that an app will apply.
public struct PinchMotion: Codable, Equatable {
    public let fromDistance: Double
    public let toDistance: Double
    public init(fromDistance: Double, toDistance: Double, duration: TimeInterval) {
        self.fromDistance = fromDistance; self.toDistance = toDistance; self.duration = duration
    }

    public let duration: TimeInterval
    public var valid: Bool {
        [fromDistance, toDistance, duration].allSatisfy(\.isFinite)
            && fromDistance >= 20 && toDistance >= 20
            && abs(fromDistance - toDistance) >= 1 && (0.1...5).contains(duration)
    }
    public func points(center: CGPoint, ending: Bool) -> [CGPoint] {
        let half = (ending ? toDistance : fromDistance) / 2
        return [CGPoint(x: center.x - half, y: center.y), CGPoint(x: center.x + half, y: center.y)]
    }
    public func regions(center: CGPoint, screen: CGRect) -> [ScreenRect] {
        zip(points(center: center, ending: false), points(center: center, ending: true)).map { start, end in
            ScreenRect(
                CGRect(
                    x: min(start.x, end.x) - 32, y: start.y - 32,
                    width: abs(end.x - start.x) + 64, height: 64
                ).intersection(screen))
        }
    }
    public var result: [String: Any] {
        [
            "fromDistance": fromDistance, "toDistance": toDistance,
            "duration": duration, "axis": "screenshot_horizontal", "distanceUnit": "screen_points"
        ]
    }
}

// XCTest's synthesized touch coordinates use the native portrait screen even
// when the screenshot and App frame are landscape. Keep guards in screenshot
// points; convert only at the Runner execution boundary.
public enum RunnerCoordinateMapping {
    public static func point(_ point: CGPoint, screen: ScreenRect, interfaceOrientation: Int) throws -> CGPoint {
        guard screen.valid, screen.cgRect.contains(point), (1...4).contains(interfaceOrientation) else {
            throw ScreenGuard.Failure.invalidGuard
        }
        let originX = point.x - screen.originX, originY = point.y - screen.originY
        switch interfaceOrientation {
        case 1: return CGPoint(x: originX, y: originY)
        case 2: return CGPoint(x: screen.width - originX, y: screen.height - originY)
        case 3: return CGPoint(x: screen.height - originY, y: originX)
        case 4: return CGPoint(x: originY, y: screen.width - originX)
        default: throw ScreenGuard.Failure.invalidGuard
        }
    }
}

public struct CoordinateGesture: Codable {
    public let start: CGPoint
    public let end: CGPoint?
    public let screenGuard: ScreenGuard
    public var motion: SwipeMotion?
    public var pinch: PinchMotion?

    public init(
        start: CGPoint, end: CGPoint?, screenGuard: ScreenGuard,
        motion: SwipeMotion? = nil, pinch: PinchMotion? = nil
    ) {
        self.start = start; self.end = end; self.screenGuard = screenGuard
        self.motion = motion; self.pinch = pinch
    }

    public var withinMotionBudget: Bool {
        guard let end, let motion else { return true }
        // XCTest documents velocity in pixels/s. Use screenshot scale for a conservative
        // estimate; this bounds requested motion, not the runtime's idle/capture overhead.
        let scale = max(
            Double(screenGuard.pixelWidth) / screenGuard.context.screen.width,
            Double(screenGuard.pixelHeight) / screenGuard.context.screen.height)
        let duration =
            motion.pressDuration + hypot(end.x - start.x, end.y - start.y) * scale / motion.velocity
            + motion.holdDuration
        return motion.valid && duration.isFinite && duration <= SwipeMotion.maximumEstimatedDuration
    }

    // Always protect the touch-down neighborhood; also protect the entire swipe corridor.
    public static func actionRegions(start: CGPoint, end: CGPoint?, screen: CGRect) -> [ScreenRect] {
        var rects = [CGRect(x: start.x - 32, y: start.y - 32, width: 64, height: 64)]
        if let end {
            rects.append(
                CGRect(
                    x: min(start.x, end.x) - 16, y: min(start.y, end.y) - 16,
                    width: abs(start.x - end.x) + 32, height: abs(start.y - end.y) + 32))
        }
        return rects.map { ScreenRect($0.intersection(screen)) }
    }

    public func validate(kind: String) throws {
        try screenGuard.validate()
        if kind == "pinch" {
            guard let pinch, pinch.valid, end == nil, motion == nil,
                [start.x, start.y].allSatisfy(\.isFinite),
                (pinch.points(center: start, ending: false) + pinch.points(center: start, ending: true))
                    .allSatisfy({
                        $0.x.isFinite && $0.y.isFinite && screenGuard.context.scope.cgRect.contains($0)
                    })
            else {
                throw ScreenGuard.Failure.invalidGuard
            }
            let required = pinch.regions(center: start, screen: screenGuard.context.screen.cgRect)
            guard screenGuard.regions.prefix(2).map(\.rect) == required else {
                throw ScreenGuard.Failure.invalidGuard
            }
            return
        }
        guard pinch == nil, [start.x, start.y].allSatisfy(\.isFinite),
            screenGuard.context.scope.cgRect.contains(start),
            (["tap", "double-tap", "long-press"].contains(kind) && end == nil && motion == nil)
                || (kind == "swipe" && end != nil && motion?.valid == true && withinMotionBudget)
        else { throw ScreenGuard.Failure.invalidGuard }
        if let end {
            guard [end.x, end.y].allSatisfy(\.isFinite), screenGuard.context.scope.cgRect.contains(end),
                hypot(end.x - start.x, end.y - start.y) >= 1
            else { throw ScreenGuard.Failure.invalidGuard }
        }
        if let overlay = screenGuard.dynamicOverlay {
            guard kind == "tap", end == nil, overlay[0].rect.cgRect.contains(start) else {
                throw ScreenGuard.Failure.invalidGuard
            }
        }
        let required = Self.actionRegions(start: start, end: end, screen: screenGuard.context.screen.cgRect)
        guard screenGuard.regions.prefix(required.count).map(\.rect) == required else {
            throw ScreenGuard.Failure.invalidGuard
        }
    }
}
