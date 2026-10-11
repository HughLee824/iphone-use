import XCTest
import CoreMedia
@testable import IPhoneUseCore

final class NativeVideoFrameMetadataTests: XCTestCase {
    private func nal(width: Int = 1184, height: Int = 2576, nativeWidth: Int = 1170, nativeHeight: Int = 2532) -> Data {
        var bytes: [UInt8] = [2, 1, 128]
        for dimension in [width, height] { bytes += [UInt8(dimension >> 8), UInt8(dimension & 255)] }
        bytes += [0, 0, 3, 0, 0]
        for dimension in [nativeWidth, nativeHeight] { bytes += [UInt8(dimension >> 8), UInt8(dimension & 255)] }
        bytes += [3]
        return Data(bytes)
    }
    func testDimensionsArePerPictureAndReducedPicturesAreNotCoordinateImages() throws {
        let canvas = CMVideoDimensions(width: 1184, height: 2576)
        let normal = try NativeVideoFrameMetadata(nals: [nal()])
        let reduced = try NativeVideoFrameMetadata(nals: [nal(width: 1088, height: 1920)])
        XCTAssertNoThrow(try normal.validate(canvas: canvas))
        XCTAssertNoThrow(try reduced.validate(canvas: canvas))
        XCTAssertTrue(normal.hasFullResolution(canvas: canvas))
        XCTAssertFalse(reduced.hasFullResolution(canvas: canvas))
        XCTAssertEqual(reduced.activeWidth, 1088); XCTAssertEqual(reduced.activeHeight, 1920)
        XCTAssertEqual(reduced.nativeWidth, 1170); XCTAssertEqual(reduced.nativeHeight, 2532)
    }
    func testUnknownFooterAndInconsistentCanvasFailClosed() throws {
        var flags = nal(); flags[flags.count - 1] = 1
        var origin = nal(); origin[7] = 1
        for nals: [Data] in [[], [Data()], [Data([2, 1])], [flags], [origin], [nal(), nal()],
                           [nal(width: 0)], [nal(width: 1183)], [nal(nativeWidth: 5000)]] {
            XCTAssertThrowsError(try NativeVideoFrameMetadata(nals: nals))
        }
        for value in [nal(width: 1200), nal(height: 2592), nal(nativeWidth: 1190), nal(nativeWidth: 1100)] {
            let metadata = try NativeVideoFrameMetadata(nals: [value])
            XCTAssertThrowsError(try metadata.validate(canvas: CMVideoDimensions(width: 1184, height: 2576)))
        }
    }
    func testProductionDecoderNeverTreatsMissingAppleMetadataAsOrdinaryHEVC() {
        let decoder = NativeSnapshotDecoder()
        XCTAssertThrowsError(try decoder.decode(NativeVideoAccessUnit(timestamp: 1, nals: [Data([2, 1, 128])], keyframe: true)))
    }
}
