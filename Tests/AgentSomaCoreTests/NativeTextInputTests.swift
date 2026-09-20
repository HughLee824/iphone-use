import XCTest
@testable import AgentSomaCore

final class NativeTextInputTests: XCTestCase {
    func testExplicitPasteAcceptsLongASCIIAndKeysNeverFallBackToClipboard() throws {
        let text = String(repeating: "Ab7 ?", count: 819) + "!"
        XCTAssertEqual(text.utf8.count, 4096)
        guard case .pasteboard(let payload) = try NativeTextInput(text: text, mode: "insert", method: "paste") else { return XCTFail("Expected literal paste") }
        XCTAssertEqual(payload, text)
        XCTAssertThrowsError(try NativeTextInput(text: text + "!", mode: "insert", method: "paste"))
        for method in ["keys", "auto"] { XCTAssertThrowsError(try NativeTextInput(text: text, mode: "insert", method: method)) }
        XCTAssertThrowsError(try NativeTextInput(text: "中文", mode: "insert", method: "keys"))
        XCTAssertThrowsError(try NativeTextInput(text: "abc", mode: "insert", method: "invalid"))
        XCTAssertThrowsError(try NativeTextInput(text: "abc\n", mode: "insert", method: "paste"))
    }

    func testMethodSurvivesActionAndObservationResolutionAndRejectsRunner() throws {
        let request: [String: Any] = ["reference": "o1", "mode": "insert", "text": String(repeating: "a", count: 100), "textMethod": "paste"]
        let action = try DeviceAction(operation: "type", request: request, allowScreenText: true)
        XCTAssertEqual(action.fields["textMethod"] as? String, "paste")
        XCTAssertThrowsError(try DeviceAction(operation: "type", request: request))
        XCTAssertThrowsError(try DeviceAction(operation: "tap", request: request, allowScreenText: true))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        let frame = CapturedObservation(nodes: [], metadata: ["backend": "apple-native", "screenContext": try jsonObject(JSONEncoder().encode(screenTestContext()))], screenshot: try screenPNG())
        _ = try cache.store(frame)
        XCTAssertNotNil(try cache.resolveTarget(for: action).textGuard)
        XCTAssertEqual(try cache.resolveTextConfirmation(ObservationReference("o1"))["backend"] as? String, "apple-native")
        XCTAssertThrowsError(try cache.resolveTextConfirmation(ObservationReference("o1:e1")))
        _ = try cache.store(frame)
        XCTAssertThrowsError(try cache.resolveTextConfirmation(ObservationReference("o1")))
    }

    func testUnicodeResolvesThroughObservationCacheAndStillRequiresCurrentSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = screenTestContext(), cache = ObservationCache(directory: directory)
        let frame = CapturedObservation(nodes: [], metadata: ["backend": "apple-native",
            "screenContext": try jsonObject(JSONEncoder().encode(context))], screenshot: try screenPNG())
        _ = try cache.store(frame)
        let action = try DeviceAction(operation: "type", request: ["reference": "o1", "mode": "insert", "text": "中文 A🙂"], allowScreenText: true)
        let target = try cache.resolveTarget(for: action)
        XCTAssertEqual(target.textGuard?.regions.map(\.rect), [context.screen])
        _ = try cache.store(frame)
        XCTAssertThrowsError(try cache.resolveTarget(for: action))
    }
    func testUnicodeIsOneWholePayloadAndExistingASCIIContractIsPreserved() throws {
        for text in ["中文", "中英 A7，🙂", "e\u{301}", "👩‍💻", String(repeating: "中", count: 1365)] {
            guard case .pasteboard(let value) = try NativeTextInput(text: text, mode: "insert") else { return XCTFail("Unicode must not be partially sent as keys") }
            XCTAssertEqual(Array(value.utf8), Array(text.utf8))
        }
        guard case .keyboard(let keys) = try NativeTextInput(text: "Ab7!?", mode: "insert") else { return XCTFail("ASCII changed") }
        XCTAssertEqual(keys, try NativeKeyboard.keys(for: "Ab7!?", mode: "insert"))
        for text in ["", "中\n文", "中\t文", "中\u{85}", "中\u{2028}", String(repeating: "中", count: 1366), String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try NativeTextInput(text: text, mode: "insert"))
        }
        XCTAssertThrowsError(try NativeTextInput(text: "中文", mode: "replace"))
    }

    func testReadOnlyPreflightAlwaysUsesOriginalGuardAndHasBoundedAttempts() throws {
        let context = screenTestContext(), baseline = try screenPNG()
        let changed = try screenPNG(patches: [(CGRect(x: 50, y: 160, width: 4, height: 10), [0,0,0])])
        let guardValue = try ScreenGuard(png: baseline, context: context,
            rects: [ScreenRect(CGRect(x: 18, y: 146, width: 354, height: 36))], policy: .init())
        let metadata: [String: Any] = ["displayID": UInt64(1), "screenContext": try jsonObject(JSONEncoder().encode(context))]
        var count = 0
        let result = try NativeInputPreflight.check(guard: guardValue, displayID: 1, deadline: 8, maximumCaptures: 3, now: { Double(count) }) {
            count += 1
            return CapturedObservation(nodes: [], metadata: metadata, screenshot: count == 3 ? baseline : changed)
        }
        XCTAssertEqual(result.1, 3)
        XCTAssertEqual(result.0.regionChanges, [0])
        count = 0
        XCTAssertThrowsError(try NativeInputPreflight.check(guard: guardValue, displayID: 1, deadline: 8, maximumCaptures: 3, now: { Double(count) }) {
            count += 1
            return CapturedObservation(nodes: [], metadata: metadata, screenshot: changed)
        }) {
            XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, false)
            XCTAssertEqual(($0 as? ActionFailure)?.rejectedCapture?.screenshot, changed)
        }
        XCTAssertEqual(count, 3)
        // Identical changed frames never establish a new baseline.
    }

    func testLateMatchingFrameAndCancellationCannotAuthorizeInput() throws {
        let context = screenTestContext(), png = try screenPNG()
        let guardValue = try ScreenGuard(png: png, context: context, rects: [context.screen], policy: .init())
        let frame = CapturedObservation(nodes: [], metadata: ["displayID": UInt64(1), "screenContext": try jsonObject(JSONEncoder().encode(context))], screenshot: png)
        var time = 0.0, captures = 0
        XCTAssertThrowsError(try NativeInputPreflight.check(guard: guardValue, displayID: 1, deadline: 8, maximumCaptures: 3, now: { time }) {
            captures += 1; time = 9; return frame
        }) { XCTAssertEqual(($0 as? ActionFailure)?.result?["preInputDeadlineExceeded"] as? Bool, true) }
        XCTAssertEqual(captures, 1)
        let cancellation = NativeCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try NativeInputPreflight.check(guard: guardValue, displayID: 1, deadline: 8, maximumCaptures: 3, now: { 0 }) {
            try cancellation.check(); captures += 1; return frame
        })
        XCTAssertEqual(captures, 1)
    }
}
