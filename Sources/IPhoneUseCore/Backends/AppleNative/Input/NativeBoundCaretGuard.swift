import IPhoneUseRunnerSupport
import Foundation

// An explicit visual assertion by the Agent, bound to the original observation.
// Only geometry is validated here. One native pixel at each vertical tip absorbs
// preview-coordinate rounding; lateral edges never expand. The mask is fixed at
// admission, clipped to the field, and never learned from a subsequent frame.
// The host does not infer a caret, background, color or opacity from those pixels.
struct NativeBoundCaretGuard {
    let observationID: String
    let caret: ScreenRect
    let exclusion: ScreenRect
    let bounds: CGRect

    init(field: NativeTextFieldGuard, caret: ScreenRect, observationID: String) throws {
        let rect = try field.nativeRect(caret)
        guard rect.minX >= 0, rect.maxX <= Double(field.width),
            rect.minY >= 0, rect.maxY <= Double(field.height)
        else {
            throw IPhoneUseError("invalid_caret_region", "Caret must be inside the complete input field")
        }
        self.observationID = observationID
        self.caret = field.screenRect(rect)
        bounds = rect.insetBy(dx: 0, dy: -1).intersection(
            CGRect(x: 0, y: 0, width: field.width, height: field.height))
        exclusion = field.screenRect(bounds)
    }
}

extension ScreenGuard.Check {
    mutating func apply(_ match: NativeTextFieldGuard.Match, caret: NativeBoundCaretGuard?) {
        fieldPixelsMatch = match == .pixels
        fieldAppearanceMatch = match == .appearance
        fieldCaretMatch = match == .caret
        caretRect = caret?.caret
        caretExclusionRect = caret?.exclusion
        caretObservationID = caret?.observationID
    }
}
