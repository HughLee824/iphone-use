import XCTest
@testable import IPhoneUseCore

// Regression coverage for the replacement of phase sampling with a source-bound
// visual assertion. Frames are synthesized; no new PNG artifacts are committed.
final class NativeTextPhaseTests: XCTestCase {
    private let context = screenTestContext()
    private let field = ScreenRect(CGRect(x: 18, y: 139, width: 354, height: 160))
    private let stroke = CGRect(x: 50, y: 150, width: 2, height: 20)
    private var caret: ScreenRect { ScreenRect(stroke.insetBy(dx: -1, dy: -1)) }

    func testAnyColorAndUnequalOpacityNeedOnlyOneCurrentFrame() throws {
        for bg: [UInt8] in [[255, 255, 255], [20, 20, 20]] {
            for color: [UInt8] in [[0, 0, 0], [255, 255, 255], [220, 30, 40], [135, 20, 180], [7, 193, 96], [20, 90, 240]] where color != bg {
                func frame(_ alpha: Double) throws -> Data {
                    try screenPNG(patches: [(context.screen.cgRect, bg), (stroke, zip(bg, color).map { UInt8((Double($0)+(Double($1)-Double($0))*alpha).rounded()) })])
                }
                for sourceAlpha in [1.0, 0.5, 0.25] {
                    if zip(bg, color).map({ abs(Double($0)-Double($1))*sourceAlpha }).max()! < 32 { continue }
                    let source = try frame(sourceAlpha)
                    let guardValue = try NativeTextFieldGuard(png: source, context: context, field: field)
                    let bound = try NativeBoundCaretGuard(field: guardValue, caret: caret, observationID: "o1")
                    for alpha in [0.0, 0.25, 0.5, 0.75, 1.0] {
                        let current = try guardValue.pixels(png: frame(alpha), context: context)
                        XCTAssertNotEqual(guardValue.compare(current, caret: bound), .none, "\(bg) \(color) \(sourceAlpha) -> \(alpha)")
                    }
                }
            }
        }
    }

    func testMissingConfirmationDoesNotLearnFromRepeatedFrames() throws {
        let value = try NativeTextFieldGuard(png: screenPNG(patches: [(stroke, [7, 193, 96])]), context: context, field: field)
        let current = try value.pixels(png: screenPNG(), context: context)
        for _ in 0..<6 {
            XCTAssertEqual(value.compare(current, caret: nil), .none)
            XCTAssertEqual(value.rejection(current, caret: nil), "caret_confirmation_required")
        }
    }

    func testHiddenCaretAcceptsRoundedBackgroundAcrossEstimatedEndpoint() throws {
        // The recorded Apple PNG averaged 254 and 255 on the two sides.
        // Its hidden caret was 255, projecting slightly past zero opacity.
        for (background, flank, color): ([UInt8], [UInt8], [UInt8]) in [
            ([255, 255, 255], [254, 254, 255], [131, 224, 176]),
            ([0, 0, 0], [1, 1, 0], [124, 31, 79]),
            ([128, 128, 128], [127, 127, 128], [30, 50, 70])
        ] {
            let unchanged = [(context.screen.cgRect, background),
                (CGRect(x: 48, y: 149, width: 1, height: 22), flank)]
            let value = try NativeTextFieldGuard(png: screenPNG(patches: unchanged + [(stroke, color)]),
                                                 context: context, field: field)
            let bound = try NativeBoundCaretGuard(field: value, caret: caret, observationID: "o1")
            let hidden = try value.pixels(png: screenPNG(patches: unchanged), context: context)
            XCTAssertEqual(value.compare(hidden, caret: bound), .caret)
        }
    }

    func testOnlyGeometryIsCheckedNotTheAgentsVisualAssertion() throws {
        let value = try NativeTextFieldGuard(png: screenPNG(), context: context, field: field)
        for rect in [field, ScreenRect(CGRect(x: 0, y: 0, width: 2, height: 20)),
                     ScreenRect(CGRect(x: 50, y: 150, width: 5, height: 20))] {
            XCTAssertThrowsError(try NativeBoundCaretGuard(field: value, caret: rect, observationID: "o1"))
        }
        // The host cannot establish that a valid box denotes a caret or focus.
        XCTAssertNoThrow(try NativeBoundCaretGuard(field: value, caret: caret, observationID: "o1"))
        let edge = ScreenRect(CGRect(x: field.x, y: field.y, width: 2, height: 20))
        XCTAssertNoThrow(try NativeBoundCaretGuard(field: value, caret: edge, observationID: "o1"))
    }

    func testConfirmedPixelsAreExcludedEvenBesidePlaceholder() throws {
        let placeholder = CGRect(x: 52, y: 155, width: 8, height: 10)
        let background: [(CGRect, [UInt8])] = [(placeholder, [178, 178, 178])]
        let value = try NativeTextFieldGuard(png: screenPNG(patches: background + [(stroke, [7, 193, 96])]),
                                             context: context, field: field)
        let bound = try NativeBoundCaretGuard(field: value, caret: ScreenRect(stroke), observationID: "o1")
        for patches in [background, background + [(stroke, [220, 30, 40])],
                        background + [(stroke, [0, 0, 0])]] {
            let current = try value.pixels(png: screenPNG(patches: patches), context: context)
            XCTAssertEqual(value.compare(current, caret: bound), .caret)
        }
    }

    func testOutsidePixelsRemainProtectedAndMaskNeverFollowsCaret() throws {
        let text = CGRect(x: 52, y: 155, width: 8, height: 10)
        let source = try screenPNG(patches: [(stroke, [7, 193, 96]), (text, [178, 178, 178])])
        let value = try NativeTextFieldGuard(png: source, context: context, field: field)
        let bound = try NativeBoundCaretGuard(field: value, caret: ScreenRect(stroke), observationID: "o1")
        let frames = try [
            screenPNG(patches: [(text, [178, 178, 178]), (stroke.offsetBy(dx: 1, dy: 0), [7, 193, 96])]),
            screenPNG(patches: [(text, [178, 178, 178]), (stroke.offsetBy(dx: 10, dy: 0), [7, 193, 96])]),
            screenPNG(), // Deletion of adjacent text is not a caret change.
            screenPNG(patches: [(text, [100, 100, 100])]),
            screenPNG(patches: [(text, [178, 178, 178]), (CGRect(x: 90, y: 150, width: 1, height: 20), [0, 0, 0])]),
            screenPNG(patches: [(stroke.insetBy(dx: -10, dy: 0), [100, 150, 200])])
        ]
        for png in frames {
            let current = try value.pixels(png: png, context: context)
            XCTAssertEqual(value.compare(current, caret: bound), .none)
            XCTAssertEqual(value.rejection(current, caret: bound), "text_field_changed")
        }
        XCTAssertEqual(bound.caret, ScreenRect(stroke))
    }

    func testNoChangesStillUseDirectComparisonWithoutCaret() throws {
        let png = try screenPNG(patches: [(stroke, [0, 0, 0])])
        let value = try NativeTextFieldGuard(png: png, context: context, field: field)
        XCTAssertEqual(value.compare(try value.pixels(png: png, context: context), caret: nil), .pixels)
        let rotated = ScreenContext(screen: context.screen, scope: context.scope, orientation: 3, keyboardCount: 0)
        XCTAssertThrowsError(try value.pixels(png: png, context: rotated))
    }

    func testAntialiasedTipsAndUnchangedAdjacentText() throws {
        func frame(_ alpha: Double) throws -> Data {
            func c(_ opacity: Double) -> [UInt8] {
                [7, 193, 96].map { UInt8((255+(Double($0)-255)*opacity).rounded()) }
            }
            return try screenPNG(patches: [(CGRect(x: 42, y: 150, width: 4, height: 20), [0, 0, 0]),
                (stroke, c(alpha)), (CGRect(x: 50, y: 150, width: 1, height: 1), c(alpha*0.2))])
        }
        let value = try NativeTextFieldGuard(png: frame(0.5), context: context, field: field)
        let bound = try NativeBoundCaretGuard(field: value, caret: caret, observationID: "o1")
        for alpha in [0.0, 0.25, 1.0] {
            XCTAssertNotEqual(value.compare(try value.pixels(png: frame(alpha), context: context), caret: bound), .none)
        }
        XCTAssertEqual(bound.observationID, "o1")
    }
}

extension NativeTextPhaseTests {
    func testRoundedTipsAllowOneNativeRowAtEveryScaleButProtectAdjacentText() throws {
        for scale in [1, 2, 3] {
            let s = CGFloat(scale)
            let selected = CGRect(x: 19, y: 479, width: 2, height: 20)
            let native = CGRect(x: selected.minX * s, y: selected.minY * s,
                                width: selected.width * s, height: selected.height * s)
            // The .20 failure omitted one antialiased row at the upper tip.
            let actual = native.insetBy(dx: 0, dy: -1)
            func frame(_ patches: [(CGRect, [UInt8])]) throws -> Data {
                try screenPNG(width: 390 * scale, height: 844 * scale, patches: patches)
            }
            let source = try frame([(actual, [135, 20, 180])])
            let value = try NativeTextFieldGuard(png: source, context: context,
                field: ScreenRect(CGRect(x: 8, y: 468, width: 295, height: 44)))
            let bound = try NativeBoundCaretGuard(field: value, caret: ScreenRect(selected), observationID: "o1")
            let hidden = try value.pixels(png: frame([]), context: context)
            XCTAssertEqual(value.compare(hidden, caret: bound), .caret)
            XCTAssertEqual(value.compare(hidden, caret: nil), .none)
            XCTAssertEqual(bound.caret, ScreenRect(selected))
            XCTAssertEqual(bound.exclusion.width, selected.width)
            XCTAssertEqual(bound.exclusion.y, selected.minY - 1 / s, accuracy: 0.000001)
            XCTAssertEqual(bound.exclusion.height, selected.height + 2 / s, accuracy: 0.000001)

            // Field and coarse-screen comparison must use the same effective mask.
            let normalized = try value.screenComparisonImage(ScreenImage(png: frame([])), caret: bound, context: context)
            let page = try ScreenGuard(png: source, context: context, rects: [ScreenRect(selected)], policy: .init())
            XCTAssertTrue(try page.check(image: normalized, context: context).accepted)

            for outside in [
                CGRect(x: native.maxX, y: native.minY + 3, width: 1, height: 8),
                CGRect(x: native.minX - 1, y: native.minY + 3, width: 1, height: 8),
                CGRect(x: native.minX, y: native.minY - 2, width: native.width, height: 1),
                CGRect(x: native.minX, y: native.maxY + 1, width: native.width, height: 1)
            ] {
                let changed = try value.pixels(png: frame([(outside, [0, 0, 0])]), context: context)
                XCTAssertEqual(value.compare(changed, caret: bound), .none)
            }
        }
    }

    func testTipPaddingClipsToFieldAndReportsEffectiveBounds() throws {
        let scoped = ScreenRect(CGRect(x: 18, y: 139, width: 40, height: 20))
        let value = try NativeTextFieldGuard(png: screenPNG(), context: context, field: scoped)
        let selected = ScreenRect(CGRect(x: 20, y: 139, width: 2, height: 20))
        let bound = try NativeBoundCaretGuard(field: value, caret: selected, observationID: "o1")
        XCTAssertEqual(bound.exclusion, selected)
        var check = ScreenGuard.Check(screenChange: 0, regionChanges: [0], policy: .init())
        check.apply(.caret, caret: bound)
        XCTAssertEqual(check.caretRect, selected)
        XCTAssertEqual(check.caretExclusionRect, selected)
        XCTAssertEqual((check.result["caretExclusionRect"] as? [String: Double])?["height"], 20)
    }

    func testFractionalFieldCoordinatesKeepNativeCaretGeometry() throws {
        let scoped = ScreenRect(CGRect(x: 18.25, y: 139.25, width: 354, height: 160))
        let png = try screenPNG(
            width: 780, height: 1688,
            patches: [(CGRect(x: 100, y: 300, width: 4, height: 40), [0, 0, 0])]
        )
        let value = try NativeTextFieldGuard(png: png, context: context, field: scoped)
        let bound = try NativeBoundCaretGuard(field: value, caret: caret, observationID: "o1")
        XCTAssertEqual(bound.caret, caret)
        XCTAssertEqual(value.compare(try value.pixels(png: screenPNG(width: 780, height: 1688), context: context), caret: bound), .caret)
    }

    func testActionBindingRequiresCurrentObservationAndIsNotInherited() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ObservationCache(directory: directory)
        let png = try screenPNG(patches: [(stroke, [7, 193, 96])])
        let capture = CapturedObservation(nodes: [], metadata: ["backend": "apple-native", "screenContext": try jsonObject(JSONEncoder().encode(context))], screenshot: png)
        _ = try cache.store(capture)
        var request: [String: Any] = ["reference": "o1", "mode": "insert", "text": "a", "fieldRect": "18,139,354,160", "caretRect": "49,149,4,22"]
        let action = try DeviceAction(operation: "type", request: request, allowScreenText: true)
        XCTAssertEqual(try cache.resolveTarget(for: action).textCaretGuard?.observationID, "o1")
        XCTAssertThrowsError(try DeviceAction(operation: "type", request: request))
        var invalid = request; invalid.removeValue(forKey: "fieldRect")
        XCTAssertThrowsError(try DeviceAction(operation: "type", request: invalid, allowScreenText: true))
        for rect in ["0,0,2,20", "49,149,40,22", "49,149,nan,22", "49,149,4,2"] {
            invalid = request; invalid["caretRect"] = rect
            XCTAssertThrowsError(try DeviceAction(operation: "type", request: invalid, allowScreenText: true))
        }
        let previous = cache.beginAction(); cache.finishAction(previous: previous, dispatched: true)
        XCTAssertThrowsError(try cache.resolveTarget(for: action))
        _ = try cache.store(capture)
        request["reference"] = "o2"; request.removeValue(forKey: "caretRect")
        XCTAssertNil(try cache.resolveTarget(for: DeviceAction(operation: "type", request: request, allowScreenText: true)).textCaretGuard)
        XCTAssertThrowsError(try cache.resolveTarget(for: action))
    }
}
