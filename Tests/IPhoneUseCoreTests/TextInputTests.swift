import XCTest
@testable import IPhoneUseCore

final class TextInputTests: XCTestCase {
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
