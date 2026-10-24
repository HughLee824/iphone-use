import Foundation
import XCTest
@testable import IPhoneUseCore

final class ToolOutputTests: XCTestCase {
    func testUTF8DiagnosticsRetainMalformedByteReplacement() {
        let samples: [([UInt8], String)] = [
            ([], ""),
            (Array("中文 café 🎥".utf8), "中文 café 🎥"),
            ([0x61, 0xff, 0x62], "a\u{FFFD}b"),
            ([0xe2, 0x82], "\u{FFFD}"),
            ([0xe2, 0x28, 0xa1], "\u{FFFD}(\u{FFFD}"),
            ([0xc0, 0xaf], "\u{FFFD}\u{FFFD}"),
            ([0xed, 0xa0, 0x80], "\u{FFFD}\u{FFFD}\u{FFFD}"),
            ([0xf4, 0x90, 0x80, 0x80], "\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}")
        ]
        for (bytes, expected) in samples {
            XCTAssertEqual(SigningTool.decodeOutput(Data(bytes)), expected)
        }
    }
}
