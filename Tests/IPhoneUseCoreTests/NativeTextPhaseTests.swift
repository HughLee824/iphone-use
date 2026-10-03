import XCTest
@testable import IPhoneUseCore

final class NativeTextPhaseTests: XCTestCase {
    private let context = screenTestContext()
    private let field = ScreenRect(CGRect(x: 18, y: 139, width: 354, height: 160))
    private let stroke = CGRect(x: 50, y: 150, width: 2, height: 20)

    private func run(source: Data, frames: [Data], clock: inout Double) throws -> (ScreenGuard.Check, Int) {
        let guardValue = try ScreenGuard(png: source, context: context, rects: [field], policy: .init())
        let fieldGuard = try NativeTextFieldGuard(png: source, context: context, field: field)
        var time = clock, index = 0
        defer { clock = time }
        return try NativeInputPreflight.check(guard: guardValue, displayID: 1, deadline: time + 8, maximumCaptures: 6,
            fieldGuard: fieldGuard, phaseSampling: true, wait: { time += $0 }, now: { time }) {
                let png = frames[min(index, frames.count - 1)]; index += 1; time += 0.03
                return CapturedObservation(nodes: [], metadata: ["displayID": UInt64(1),
                    "screenContext": try jsonObject(JSONEncoder().encode(self.context))], screenshot: png)
            }
    }

    func testAnyColorOrSourcePhaseMatchesWithoutMasking() throws {
        for bg: [UInt8] in [[255,255,255], [20,20,20]] {
            for color: [UInt8] in [[0,0,0], [255,255,255], [220,30,40], [135,20,180], [7,193,96], [20,90,240]] where color != bg {
                let hidden = try screenPNG(patches: [(context.screen.cgRect, bg)])
                let visible = try screenPNG(patches: [(context.screen.cgRect, bg), (stroke, color)])
                let fade = zip(color, bg).map { UInt8((Int($0) + Int($1)) / 2) }
                let partial = try screenPNG(patches: [(context.screen.cgRect, bg), (stroke, fade)])
                for (source, frames) in [(visible, [hidden, partial, visible]), (hidden, [visible, partial, hidden]),
                                          (partial, [hidden, visible, partial])] {
                    var clock = 0.0
                    let result = try run(source: source, frames: frames, clock: &clock)
                    XCTAssertEqual(result.1, 3)
                    XCTAssertTrue(result.0.accepted)
                    XCTAssertEqual(result.0.fieldPixelsMatch, true)
                    XCTAssertNil(result.0.result["caretBlinkException"])
                }
            }
        }
    }

    func testThinTextChangesAndMovedCaretNeverBecomeNewBaseline() throws {
        let original = try screenPNG(patches: [(stroke, [200,20,180])])
        for patch in [CGRect(x: 82, y: 151, width: 1, height: 14), // I, l or | sized stroke
                      stroke.offsetBy(dx: 2, dy: 0), stroke.insetBy(dx: -4, dy: 0)] {
            let changed = try screenPNG(patches: [(stroke, [200,20,180]), (patch, [0,0,0])])
            var clock = 0.0
            XCTAssertThrowsError(try run(source: original, frames: [changed], clock: &clock)) {
                XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, false)
                XCTAssertEqual(($0 as? ActionFailure)?.result?["preInputCaptures"] as? Int, 6)
            }
            XCTAssertGreaterThanOrEqual(clock, 1.97)
        }
    }

    func testMatchingFirstFrameHasNoSamplingDelay() throws {
        let original = try screenPNG()
        var clock = 0.0
        XCTAssertEqual(try run(source: original, frames: [original], clock: &clock).1, 1)
        XCTAssertEqual(clock, 0.03)
    }

    func testIntermediatePhaseUsesObservedCycleWithoutRequiringSameOpacity() throws {
        for bg: [UInt8] in [[255,255,255], [20,20,20]] {
            for color: [UInt8] in [[0,0,0], [255,255,255], [220,30,40], [135,20,180], [7,193,96], [20,90,240]] where color != bg {
                let hidden = try screenPNG(patches: [(context.screen.cgRect, bg)])
                let visible = try screenPNG(patches: [(context.screen.cgRect, bg), (stroke, color)])
                let fade = zip(color, bg).map { UInt8((Int($0) + Int($1)) / 2) }
                let partial = try screenPNG(patches: [(context.screen.cgRect, bg), (stroke, fade)])
                var clock = 0.0
                let result = try run(source: partial, frames: [hidden, visible, hidden], clock: &clock)
                XCTAssertEqual(result.1, 3)
                XCTAssertTrue(result.0.accepted)
                XCTAssertEqual(result.0.fieldPixelsMatch, false)
                XCTAssertTrue(result.0.fieldTemporalMatch)
            }
        }
    }

    func testTemporalCycleCannotExplainChangedTextMovingStrokeOrSelection() throws {
        let hidden = try screenPNG(), visible = try screenPNG(patches: [(stroke, [0,0,0])])
        let partial = try screenPNG(patches: [(stroke, [128,128,128])])
        let changed = CGRect(x: 80, y: 160, width: 1, height: 16)
        let cases: [(Data, [Data])] = [
            (partial, [hidden, visible]), // no returning phase (last frame repeats)
            (try screenPNG(patches: [(stroke, [128,128,128]), (changed, [0,0,0])]), [hidden, visible, hidden]),
            (partial, [try screenPNG(patches: [(changed, [0,0,0])]),
                       try screenPNG(patches: [(changed, [0,0,0]), (stroke, [0,0,0])]),
                       try screenPNG(patches: [(changed, [0,0,0])])]),
            (partial, [visible, try screenPNG(patches: [(stroke.offsetBy(dx: 1, dy: 0), [0,0,0])]), visible]),
            (try screenPNG(patches: [(stroke.insetBy(dx: -10, dy: 0), [128,128,128])]),
             [hidden, try screenPNG(patches: [(stroke.insetBy(dx: -10, dy: 0), [0,0,0])]), hidden])
        ]
        for (source, frames) in cases {
            var clock = 0.0
            XCTAssertThrowsError(try run(source: source, frames: frames, clock: &clock))
        }
    }

    func testVideoNoiseBudgetRejectsConnectedStrokesAndStrongOrExcessNoise() throws {
        let guardValue = try NativeTextFieldGuard(png: screenPNG(), context: context, field: field)
        let isolated = (0..<4).map { (CGRect(x: 80 + $0 * 4, y: 160, width: 1, height: 1), [UInt8](repeating: 245, count: 3)) }
        XCTAssertTrue(try guardValue.matches(png: screenPNG(patches: isolated), context: context))
        let rejected: [[(CGRect, [UInt8])]] = [
            isolated + [(CGRect(x: 120, y: 160, width: 1, height: 1), [245,245,245])],
            [(CGRect(x: 80, y: 160, width: 1, height: 2), [245,245,245])],
            [(CGRect(x: 80, y: 160, width: 1, height: 1), [238,238,238])],
            [(CGRect(x: 80, y: 160, width: 1, height: 1), [245,245,245]),
             (CGRect(x: 81, y: 161, width: 1, height: 1), [245,245,245])]
        ]
        for patches in rejected {
            XCTAssertFalse(try guardValue.matches(png: screenPNG(patches: patches), context: context))
        }
    }

    func testVideoRimDoesNotAbortCaretPhaseSampling() throws {
        let textField = ScreenRect(CGRect(x: 17, y: 209, width: 356, height: 161))
        let ignored = ScreenRect(CGRect(x: 18, y: 89, width: 177, height: 60))
        let rim = CGRect(x: 53, y: 266, width: 533, height: 182)
        let caret = CGRect(x: 643, y: 646, width: 8, height: 61)
        let source = try screenPNG(width: 1170, height: 2532, patches: [(rim, [255,145,30]), (caret, [255,128,128])])
        let hidden = try screenPNG(width: 1170, height: 2532, patches: [(rim, [0,183,211])])
        let visible = try screenPNG(width: 1170, height: 2532, patches: [(rim, [0,183,211]), (caret, [255,0,0])])
        let value = try ScreenGuard(png: source, context: context, rects: [textField], policy: .init(), ignoring: ignored)
        let fieldGuard = try NativeTextFieldGuard(png: source, context: context, field: textField)
        var time = 0.0, index = 0
        let frames = [hidden, visible, hidden]
        let result = try NativeInputPreflight.check(guard: value, displayID: 1, deadline: 8, maximumCaptures: 6,
            fieldGuard: fieldGuard, phaseSampling: true, wait: { time += $0 }, now: { time }) {
                let png = frames[min(index, 2)]; index += 1; time += 0.03
                return CapturedObservation(nodes: [], metadata: ["displayID": UInt64(1),
                    "screenContext": try jsonObject(JSONEncoder().encode(self.context))], screenshot: png)
            }
        XCTAssertEqual(result.1, 3)
        XCTAssertTrue(result.0.accepted)
        XCTAssertTrue(result.0.fieldTemporalMatch)
        XCTAssertEqual(result.0.fieldPixelsMatch, false)
        XCTAssertEqual(result.0.ignoredRect, ignored)
    }

    func testCancellationDuringPhaseWaitDoesNotCaptureOrDispatchAgain() throws {
        let original = try screenPNG(), changed = try screenPNG(patches: [(stroke, [0,0,0])])
        let guardValue = try ScreenGuard(png: original, context: context, rects: [field], policy: .init())
        let fieldGuard = try NativeTextFieldGuard(png: original, context: context, field: field)
        var captures = 0
        let cancellation = NativeCancellation()
        XCTAssertThrowsError(try NativeInputPreflight.check(guard: guardValue, displayID: 1, deadline: 8, maximumCaptures: 6,
            fieldGuard: fieldGuard, phaseSampling: true,
            wait: { _ in cancellation.cancel(); try cancellation.check() }, now: { 0 }) {
                captures += 1
                return CapturedObservation(nodes: [], metadata: ["displayID": UInt64(1),
                    "screenContext": try jsonObject(JSONEncoder().encode(self.context))], screenshot: changed)
            })
        XCTAssertEqual(captures, 1)
    }
}
