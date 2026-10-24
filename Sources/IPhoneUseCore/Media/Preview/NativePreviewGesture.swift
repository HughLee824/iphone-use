import Foundation

// A short-lived visual receipt, not an input acknowledgement or a touch stream.
// Only geometric information crosses into the browser; no AX labels or typed text.
struct NativePreviewGesture {
    let kind: String
    let rotation: String
    let aspect: Double
    let paths: [[[Double]]]

    init?(action: DeviceAction, target: ObservedTarget, previewRotation: String? = nil) {
        guard ["tap", "double-tap", "long-press", "swipe", "pinch"].contains(action.kind),
            let gesture = target.gesture
        else { return nil }
        let context = gesture.screenGuard.context, screen = context.screen
        // XCTest reports physical orientation (including face-up/down), not
        // interface orientation. Bind to the preview BEFORE dispatch instead.
        guard screen.valid,
            let rotation = previewRotation
                ?? [1: "rot0", 2: "rot180", 3: "rot270", 4: "rot90"][context.orientation],
            ["rot0", "rot90", "rot180", "rot270"].contains(rotation)
        else { return nil }
        let pairs: [(CGPoint, CGPoint)]
        if let pinch = gesture.pinch {
            pairs = Array(
                zip(
                    pinch.points(center: gesture.start, ending: false),
                    pinch.points(center: gesture.start, ending: true)))
        } else {
            pairs = [(gesture.start, gesture.end ?? gesture.start)]
        }
        guard pairs.allSatisfy({ screen.cgRect.contains($0.0) && screen.cgRect.contains($0.1) }) else {
            return nil
        }
        func normalized(_ point: CGPoint) -> [Double] {
            [(point.x - screen.originX) / screen.width, (point.y - screen.originY) / screen.height]
        }
        // A swipe with an explicit touch-down or release hold is a drag receipt.
        // Keep this distinction visual; the dispatched input remains unchanged.
        let motion = gesture.motion ?? action.swipeMotion
        kind =
            action.kind == "swipe" && ((motion?.pressDuration ?? 0) > 0 || (motion?.holdDuration ?? 0) > 0)
            ? "drag" : action.kind
        self.rotation = rotation; aspect = screen.width / screen.height
        paths = pairs.map { [normalized($0.0), normalized($0.1)] }
    }

    var facts: [String: Any] { ["kind": kind, "rotation": rotation, "aspect": aspect, "paths": paths] }
}

// Accessed only on NativePreview's HTTP queue. Bound memory, expire old actions,
// and use a cursor so polling, reconnects and multiple viewers never replay input.
struct NativePreviewGestures {
    private(set) var sequence = 0
    private struct Event {
        let sequence: Int
        let timestamp: Double
        let facts: [String: Any]
    }
    private var events: [Event] = []
    mutating func append(_ gesture: NativePreviewGesture, now: Double) {
        sequence += 1
        events.append(Event(sequence: sequence, timestamp: now, facts: gesture.facts))
        events = Array(events.suffix(16))
    }
    mutating func clear() { events.removeAll() }
    func response(after: Int?, now: Double) -> [String: Any] {
        let recent = events.filter {
            after != nil && $0.sequence > after! && now - $0.timestamp < 2 && now >= $0.timestamp
        }
        return [
            "sequence": sequence,
            "events": recent.map { event in
                var facts = event.facts; facts["sequence"] = event.sequence; return facts
            }
        ]
    }
}
