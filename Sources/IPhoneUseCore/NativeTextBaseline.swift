import Foundation

// Only used while producing a NEW observation, never to replace an action's source.
struct NativeTextObservationOptions: Codable {
    let field: ScreenRect
    let ignoring: ScreenRect?

    init(field: ScreenRect, ignoring: ScreenRect?) { self.field = field; self.ignoring = ignoring }
    init(request: [String: Any]) throws {
        func rect(_ value: Any?, code: String) throws -> ScreenRect {
            guard let value = value as? String else { throw IPhoneUseError(code, "Use x,y,width,height in screen points") }
            let parts = value.split(separator: ",", omittingEmptySubsequences: false)
            let values = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.count == 4, values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else {
                throw IPhoneUseError(code, "Use a finite positive rectangle x,y,width,height")
            }
            let result = ScreenRect(CGRect(x: values[0], y: values[1], width: values[2], height: values[3]))
            guard result.valid else { throw IPhoneUseError(code, "Invalid rectangle") }
            return result
        }
        field = try rect(request["fieldRect"], code: "invalid_text_region")
        ignoring = try request["ignoreRect"].map { try rect($0, code: "invalid_ignored_region") }
    }
    var result: [String: Any] { get throws { try jsonObject(JSONEncoder().encode(self)) } }
}

// A bounded rolling set allows an early encoded picture to be discarded BEFORE
// the user sees the observation. All comparisons retain the existing guard rules.
final class NativeTextBaseline {
    static let budget: TimeInterval = 3
    static let interval: TimeInterval = 0.25
    static let maximumSamples = 10
    private final class Candidate {
        let started: TimeInterval
        let guardValue: ScreenGuard
        let matcher: NativeTextPhaseMatcher
        var matches = 0
        init(png: Data, context: ScreenContext, options: NativeTextObservationOptions, at: TimeInterval) throws {
            started = at
            guardValue = try ScreenGuard(png: png, context: context, rects: [options.field], policy: .init(), ignoring: options.ignoring)
            matcher = NativeTextPhaseMatcher(field: try NativeTextFieldGuard(png: png, context: context, field: options.field))
        }
    }
    private let options: NativeTextObservationOptions
    private var candidates: [Candidate] = []
    private(set) var samples = 0
    private(set) var evidenceSpan: TimeInterval = 0
    init(options: NativeTextObservationOptions) { self.options = options }

    func accept(png: Data, context: ScreenContext, at: TimeInterval) throws -> Bool {
        guard samples < Self.maximumSamples else { return false }
        samples += 1
        for candidate in candidates {
            var check = try candidate.guardValue.check(png: png, context: context)
            check.apply(try candidate.matcher.check(png: png, context: context), caret: candidate.matcher.caretRect)
            if check.accepted {
                candidate.matches += 1
                // Two corroborating later pictures, separated in time, avoid
                // accepting duplicate/bursty initial pictures as a stable baseline.
                if candidate.matches >= 2, at - candidate.started >= 0.6 {
                    evidenceSpan = at - candidate.started
                    return true
                }
            } else {
                candidate.matches = 0
            }
        }
        candidates.append(try Candidate(png: png, context: context, options: options, at: at))
        if candidates.count > 6 { candidates.removeFirst() }
        return false
    }
    var result: [String: Any] {
        ["strategy": "bounded_field_stability_v1", "samples": samples,
         "evidenceSpanSeconds": evidenceSpan, "budgetSeconds": Self.budget,
         "established": evidenceSpan > 0]
    }
}
