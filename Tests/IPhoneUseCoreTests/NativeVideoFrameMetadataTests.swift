import XCTest
import CoreMedia
@testable import IPhoneUseCore

final class NativeVideoFrameMetadataTests: XCTestCase {
    private func nal(width: Int = 1184, height: Int = 2576, nativeWidth: Int = 1170, nativeHeight: Int = 2532) -> Data {
        var bytes: [UInt8] = [2, 1, 128]
        for dimension in [width, height] { bytes += [UInt8(dimension >> 8), UInt8(dimension & 255)] }
        bytes += [0, 0, 0, 0]
        for dimension in [nativeWidth, nativeHeight] { bytes += [UInt8(dimension >> 8), UInt8(dimension & 255)] }
        bytes += [3]
        var encoded: [UInt8] = [], zeros = 0
        for byte in bytes {
            if zeros == 2 && byte <= 3 { encoded.append(3); zeros = 0 }
            encoded.append(byte); zeros = byte == 0 ? zeros + 1 : 0
        }
        return Data(encoded)
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
    func testCapturedReducedPictureWithExtraEscapeParsesWithoutMetadataError() throws {
        // 2026-10-16: healthy RTP, zero gaps; old fixed-14-byte parser rejected
        // this exact captured suffix and forced a full preview stream rebuild.
        let hex = "1809580988099809b809c80a080a38011702d00500000300000300049209e403"
        let bytes = stride(from: 0, to: hex.count, by: 2).map { i in
            UInt8(hex.dropFirst(i).prefix(2), radix: 16)!
        }
        let frame = try NativeVideoFrameMetadata(nals: [Data([2, 1]) + Data(bytes)])
        XCTAssertEqual(frame.activeWidth, 720); XCTAssertEqual(frame.activeHeight, 1280)
        XCTAssertEqual(frame.nativeWidth, 1170); XCTAssertEqual(frame.nativeHeight, 2532)
        XCTAssertNoThrow(try frame.validate(canvas: CMVideoDimensions(width: 1184, height: 2576)))
        XCTAssertFalse(frame.hasFullResolution(canvas: CMVideoDimensions(width: 1184, height: 2576)))
        for height in [256, 768, 1024, 1280, 1792, 2048, 2560] {
            XCTAssertEqual(try NativeVideoFrameMetadata(nals: [nal(height: height)]).activeHeight, height)
        }
    }

    func testMalformedEscapesAreRejectedWithoutSearchingForAnotherFooter() throws {
        var missing = nal(height: 1280)
        let escape = try XCTUnwrap(missing.indices.first { $0 > 2 && missing[$0] == 3
            && missing[$0 - 1] == 0 && missing[$0 - 2] == 0 })
        missing.remove(at: escape)
        var invalidFollower = nal(height: 1280)
        invalidFollower[escape + 1] = 4
        var truncatedEscape = nal()
        truncatedEscape.append(contentsOf: [0, 0, 3])
        for invalid in [missing, invalidFollower, truncatedEscape, nal() + Data([0xff])] {
            XCTAssertThrowsError(try NativeVideoFrameMetadata(nals: [invalid])) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, "native_video_metadata_invalid")
            }
        }
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
