import XCTest
@testable import IPhoneUseCore

final class NativeTextBaselineTests: XCTestCase {
    private let context = screenTestContext()
    private let field = ScreenRect(CGRect(x: 18, y: 139, width: 354, height: 160))
    private func options() -> NativeTextObservationOptions { .init(field: field, ignoring: nil) }

    func testStablePicturesNeedTimeAndTwoCorroborations() throws {
        let baseline = NativeTextBaseline(options: options()), png = try screenPNG()
        XCTAssertFalse(try baseline.accept(png: png, context: context, at: 0))
        XCTAssertFalse(try baseline.accept(png: png, context: context, at: 0.01))
        XCTAssertFalse(try baseline.accept(png: png, context: context, at: 0.02))
        XCTAssertTrue(try baseline.accept(png: png, context: context, at: 0.75))
    }
    func testChangingFieldNeverBecomesBaselineAndWorkIsBounded() throws {
        let baseline = NativeTextBaseline(options: options())
        for i in 0..<12 {
            let png = try screenPNG(patches: [(CGRect(x: 30 + i * 4, y: 150, width: 2, height: 20), [0,0,0])])
            XCTAssertFalse(try baseline.accept(png: png, context: context, at: Double(i) * 0.25))
        }
        XCTAssertEqual(baseline.samples, NativeTextBaseline.maximumSamples)
    }
    func testEstablishedSourceStillRejectsChangedText() throws {
        let png = try screenPNG(), baseline = NativeTextBaseline(options: options())
        _ = try baseline.accept(png: png, context: context, at: 0)
        _ = try baseline.accept(png: png, context: context, at: 0.25)
        XCTAssertTrue(try baseline.accept(png: png, context: context, at: 0.75))
        let source = try NativeTextFieldGuard(png: png, context: context, field: field)
        let matcher = NativeTextPhaseMatcher(field: source)
        let changed = try screenPNG(patches: [(CGRect(x: 40, y: 160, width: 1, height: 18), [0,0,0])])
        for _ in 0..<6 { XCTAssertEqual(try matcher.check(png: changed, context: context), .none) }
    }
    func testRealStartupDriftCanRollForwardOnlyBeforeObservationIsIssued() throws {
        let rect = ScreenRect(CGRect(x:0,y:0,width:354,height:160))
        let context = ScreenContext(screen:rect,scope:rect,orientation:1,keyboardCount:0)
        func fixture(_ index: Int) throws -> Data {
            try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource:"startup-\(index)",withExtension:"png",subdirectory:"Fixtures/NativeText")))
        }
        let original = try fixture(0)
        let oldMatcher = NativeTextPhaseMatcher(field: try NativeTextFieldGuard(png:original,context:context,field:rect))
        let baseline = NativeTextBaseline(options:.init(field:rect,ignoring:nil))
        XCTAssertFalse(try baseline.accept(png:original,context:context,at:0))
        for frame in [100,400,500] {
            let png = try fixture(frame)
            XCTAssertEqual(try oldMatcher.check(png:png,context:context), .none)
            XCTAssertEqual(try baseline.accept(png:png,context:context,at:Double(frame)/100*0.35), frame == 500)
        }
    }
    func testExplicitAnimationExclusionDoesNotIncludeField() throws {
        let video = ScreenRect(CGRect(x:18,y:70,width:160,height:50))
        let baseline = NativeTextBaseline(options:.init(field:field,ignoring:video))
        var accepted = false
        for i in 0..<5 {
            let png = try screenPNG(patches:[(video.cgRect, i % 2 == 0 ? [0,0,0] : [255,0,0])])
            accepted = try baseline.accept(png:png,context:context,at:Double(i)*0.25)
            if accepted { break }
        }
        XCTAssertTrue(accepted)
        let invalid = NativeTextBaseline(options:.init(field:field,ignoring:field))
        XCTAssertThrowsError(try invalid.accept(png:screenPNG(),context:context,at:0))
    }
    func testMalformedOptionsFailBeforePreparation() throws {
        for value in ["0,0,0,10", "0,0,-1,10", "nan,0,10,10", "1,2,3"] {
            XCTAssertThrowsError(try NativeTextObservationOptions(request:["fieldRect":value]))
        }
        XCTAssertThrowsError(try NativeTextObservationOptions(request:["ignoreRect":"0,0,10,10"]))
    }
}
