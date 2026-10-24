import IPhoneUseRunnerSupport
import Foundation

extension ActionRequest {
    func guardPolicy(reference: ObservationReference) throws -> (ScreenGuard.Policy, [ObservationReference]) {
        var policy = ScreenGuard.Policy()
        var protected: [ObservationReference] = []
        if ["tap", "double-tap", "long-press", "pinch", "swipe"].contains(operation) {
            if request["maxScreenChange"] != nil {
                guard let value = Self.number(request["maxScreenChange"]) else {
                    throw IPhoneUseError("invalid_screen_guard_policy", "Screen change limit must be finite")
                }
                policy.maxScreenChange = value
            }
            if request["maxRegionChange"] != nil {
                guard let value = Self.number(request["maxRegionChange"]) else {
                    throw IPhoneUseError("invalid_screen_guard_policy", "Region change limit must be finite")
                }
                policy.maxRegionChange = value
            }
            guard policy.valid else {
                throw IPhoneUseError(
                    "invalid_screen_guard_policy", "Require 0 <= max-region-change <= max-screen-change <= 1")
            }
            if let value = request["protect"] {
                guard let refs = value as? [String], refs.count <= 3 else {
                    throw IPhoneUseError(
                        "invalid_protected_regions",
                        "Protect up to three element references from the same observation")
                }
                let observation = reference.observation
                protected = try refs.map { value in
                    let ref = try ObservationReference(value)
                    guard ref.observation == observation, ref.node != nil else {
                        throw IPhoneUseError(
                            "invalid_protected_regions",
                            "Protected elements must belong to the action's observation")
                    }
                    return ref
                }
            }
        }
        return (policy, protected)
    }

    func dynamicRects(
        coordinate: Bool, ignoredScreenRect: ScreenRect?, protected: [ObservationReference],
        policy: ScreenGuard.Policy
    ) throws -> [ScreenRect]? {
        if request["dynamicTarget"] != nil || request["dynamicAnchor"] != nil {
            guard operation == "tap", coordinate, ignoredScreenRect == nil, protected.isEmpty,
                policy.maxScreenChange == 0.01, policy.maxRegionChange == 0
            else {
                throw IPhoneUseError(
                    "invalid_dynamic_target",
                    """
                    Dynamic overlay validation requires a coordinate tap with default guard policy and no\
                     ignore/protect options
                    """
                )
            }
            return try ["dynamicTarget", "dynamicAnchor"].map { key in
                guard let raw = request[key] as? String else {
                    throw IPhoneUseError(
                        "invalid_dynamic_target", "Supply both --dynamic-target and --dynamic-anchor")
                }
                let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
                let value = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard parts.count == 4, value.count == 4, value.allSatisfy(\.isFinite), value[2] > 0,
                    value[3] > 0
                else {
                    throw IPhoneUseError(
                        "invalid_dynamic_target", "Use x,y,width,height in screenshot points")
                }
                return ScreenRect(CGRect(x: value[0], y: value[1], width: value[2], height: value[3]))
            }
        } else {
            return nil
        }
    }
}
