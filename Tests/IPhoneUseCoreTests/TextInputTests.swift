import XCTest
@testable import IPhoneUseCore

final class TextInputTests: XCTestCase {
    func testRunnerReplacementBoundsDeletionAndPreservesExactPayload() throws {
        let text = " 头👩‍💻e\u{301}\n尾 "
        XCTAssertEqual(try RunnerTextInput.replacementInput(text, value: "", secure: false, placeholder: nil, deleteKey: "\u{7f}"), text)
        XCTAssertEqual(try RunnerTextInput.replacementInput("", value: "old", secure: false, placeholder: nil, deleteKey: "\u{7f}"),
                       String(repeating: "\u{7f}", count: 3))
        XCTAssertEqual(try RunnerTextInput.replacementInput("", value: "", secure: false, placeholder: nil, deleteKey: "\u{7f}"), "")
        XCTAssertEqual(try RunnerTextInput.replacementInput("", value: String(repeating: "a", count: 4096),
            secure: false, placeholder: nil, deleteKey: "\u{7f}").utf16.count, 4096)
        for source: Any? in [nil, NSNull(), 42, "Search", String(repeating: "a", count: 4097)] {
            XCTAssertThrowsError(try RunnerTextInput.replacementInput("new", value: source,
                secure: false, placeholder: "Search", deleteKey: "\u{7f}")) {
                XCTAssertEqual($0 as? RunnerTextInput.Failure, .clearValueUnavailable)
            }
        }
        XCTAssertThrowsError(try RunnerTextInput.replacementInput("new", value: "•••", secure: true, placeholder: nil, deleteKey: "\u{7f}"))
        let appended = try RunnerTextInput.append("尾", to: "头🙂", secure: false)
        XCTAssertEqual(try RunnerTextInput.replacementInput(appended, value: "头🙂", secure: false, placeholder: nil, deleteKey: "\u{7f}"),
                       String(repeating: "\u{7f}", count: 3) + "头🙂尾")
    }

    func testRunnerClearConfirmationAcceptsUIKitEmptyValueAndRejectsResidualText() {
        XCTAssertTrue(RunnerTextInput.isCleared(nil))
        XCTAssertTrue(RunnerTextInput.isCleared(""))
        for value: Any in ["尾", " ", "\n", "Placeholder", NSNull(), 0] {
            XCTAssertFalse(RunnerTextInput.isCleared(value))
        }
    }

    func testRunnerAppendReconstructsExactTextAndRejectsUnreadableOrUnsafeSource() throws {
        let source = " 头🙂\ne\u{301} "
        let suffix = "尾\n"
        XCTAssertEqual(Array(try RunnerTextInput.append(suffix, to: source, secure: false).utf8), Array((source + suffix).utf8))
        XCTAssertEqual(try RunnerTextInput.append("尾", to: "", secure: false), "尾")
        for value: Any? in [nil, NSNull(), 123] {
            XCTAssertThrowsError(try RunnerTextInput.append("尾", to: value, secure: false))
        }
        XCTAssertThrowsError(try RunnerTextInput.append("尾", to: "•••", secure: true))
        XCTAssertThrowsError(try RunnerTextInput.append("尾", to: "Placeholder", secure: false, placeholder: "Placeholder"))
        XCTAssertThrowsError(try RunnerTextInput.append("尾", to: "old\ttext", secure: false))
        XCTAssertThrowsError(try RunnerTextInput.append("尾", to: "old\r\ntext", secure: false))
        XCTAssertEqual(try RunnerTextInput.append("尾", to: String(repeating: "a", count: 4093), secure: false).utf8.count, 4096)
        XCTAssertThrowsError(try RunnerTextInput.append("尾", to: String(repeating: "a", count: 4094), secure: false))
    }

    private func read(_ data: Data) throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("as-text-\(UUID().uuidString)")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        return try TextInput.read(from: input)
    }

    func testReadsUTF8ExactlyIncludingEmptyWhitespaceAndByteLimit() throws {
        for text in ["", "  北京👩‍💻e\u{301} $HOME `literal`  ", "text\n", String(repeating: "北", count: 1365) + "a"] {
            XCTAssertEqual(try read(Data(text.utf8)), text)
        }
    }

    func testRejectsInvalidUTF8AndOversizedText() throws {
        for data in [Data([0xff]), Data([0xe5, 0x8c]), Data(String(repeating: "北", count: 1366).utf8)] {
            XCTAssertThrowsError(try read(data)) { XCTAssertEqual(($0 as? IPhoneUseError)?.code, "invalid_text") }
        }
    }

    func testOversizedPipeFailsWithoutWaitingForEOF() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close() }
        let rejected = expectation(description: "oversized input rejected before EOF")
        DispatchQueue.global().async {
            defer { try? pipe.fileHandleForReading.close(); rejected.fulfill() }
            do {
                _ = try TextInput.read(from: pipe.fileHandleForReading)
                XCTFail("Oversized stream was accepted")
            } catch { XCTAssertEqual((error as? IPhoneUseError)?.code, "invalid_text") }
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: 65, count: 4097))
        wait(for: [rejected], timeout: 2)
    }
}
