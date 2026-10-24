import IPhoneUseRunnerSupport
import Foundation
import CoreGraphics
import ImageIO
import AppleNativeBridge

struct NativeDisplay: Equatable {
    struct Geometry: Equatable {
        let id: UInt64
        let width: Double, height: Double, scale: Double
        let rotation: String, nativeRotation: String
        init(_ display: NativeDisplay) {
            id = display.id; width = display.pixelWidth; height = display.pixelHeight
            scale = display.scale; rotation = display.rotation; nativeRotation = display.nativeRotation
        }
    }
    var geometry: Geometry { Geometry(self) }
    let id: UInt64
    let pixelWidth: Double
    let pixelHeight: Double
    let scale: Double
    let rotation: String
    let nativeRotation: String
    let backlightOn: Bool
    var screen: ScreenRect {
        ScreenRect(CGRect(x: 0, y: 0, width: pixelWidth / scale, height: pixelHeight / scale))
    }
    var context: ScreenContext {
        let orientation = ["rot0": 1, "rot90": 4, "rot180": 2, "rot270": 3][rotation] ?? 0
        // Native screenshots have no keyboard/AX count; this placeholder is only for grid
        // comparison. keyboardState is explicitly unknown in the observation metadata.
        return ScreenContext(screen: screen, scope: screen, orientation: orientation, keyboardCount: 0)
    }
    init(_ result: [String: Any]) throws {
        guard let displays = result["displays"] as? [[String: Any]] else {
            throw IPhoneUseError("native_display_unavailable", "Display list missing")
        }
        let primary = displays.filter { $0["primary"] as? Bool == true }
        guard primary.count == 1, let value = primary.first,
            let id = value["displayId"] as? NSNumber, id.uint64Value > 0,
            let bounds = value["bounds"] as? [[NSNumber]], bounds.count == 2,
            bounds.allSatisfy({ $0.count == 2 }),
            bounds[0].map(\.doubleValue) == [0, 0],
            bounds[1].allSatisfy({ $0.doubleValue.isFinite && $0.doubleValue > 0 && $0.doubleValue <= 16384 }
            ),
            let scale = value["pointScale"] as? NSNumber, scale.doubleValue.isFinite, scale.doubleValue >= 1,
            let rotation = value["currentOrientation"] as? String,
            ["rot0", "rot90", "rot180", "rot270"].contains(rotation),
            let native = value["nativeOrientation"] as? String,
            ["rot0", "rot90", "rot180", "rot270"].contains(native)
        else { throw IPhoneUseError("native_display_unavailable", "Unknown primary display geometry") }
        // CoreDevice bounds remain in native display axes when the scene rotates;
        // devicectl's PNG is already oriented. Do not rotate or resample that PNG.
        let quarterTurn = ["rot90", "rot270"].contains(rotation) != ["rot90", "rot270"].contains(native)
        self.id = id.uint64Value
        pixelWidth = bounds[1][quarterTurn ? 1 : 0].doubleValue
        pixelHeight = bounds[1][quarterTurn ? 0 : 1].doubleValue
        self.scale = scale.doubleValue
        self.rotation = rotation; nativeRotation = native
        // XCTest can leave an unlocked, visible display dimmed. Both active
        // states are lit; inactive and unknown states still fail closed.
        backlightOn = ["activeOn", "activeDimmed"].contains(result["backlightState"] as? String ?? "")
    }
}
