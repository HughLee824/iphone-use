import XCTest
import CoreGraphics
import AppleNativeBridge
import Darwin
@testable import IPhoneUseCore

extension AppleNativeTests {

    func testTransportDiagnosticsDoNotSendRequestsOrReopenAfterCancellation() {
        let channel = ReplyChannel()
        let observed = AppleServiceTransport(channel: channel)
        XCTAssertEqual(observed.diagnostics["locallyClosed"] as? Bool, false)
        observed.cancel()
        XCTAssertEqual(observed.diagnostics["locallyClosed"] as? Bool, true)
        XCTAssertTrue(channel.callbacks.isEmpty)
        XCTAssertEqual(channel.sends, 0)
        XCTAssertEqual(channel.cancellations, 1)
    }

    func testInstalledAppleMediaOfferWhenExplicitlyRequested() throws {
        guard ProcessInfo.processInfo.environment["IPHONE_USE_NATIVE_HOST_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in installed-framework check, not a portable device test")
        }
        let negotiator = try ASMediaNegotiator(error: ())
        XCTAssertGreaterThan(negotiator.offer.count, 0)
        XCTAssertNoThrow(try PropertyListSerialization.propertyList(from: negotiator.offer, format: nil))
    }

    func testEndpointInventoryMatchesCompleteIPv6AndOwner() {
        let inventory = """
            tcp6 0 0 fd00::2.4000 fd00::1.5000 ESTABLISHED 10 20 30 40 remoted:123 00000
            tcp6 0 0 fd00::2.4001 fd00::3.6000 ESTABLISHED 10 20 30 40 remoted:123 00000
            tcp6 0 0 fd00::2.4002 fd00::1.7000 ESTABLISHED 10 20 30 40 another:456 00000
            tcp6 0 0 fd00::1.8000 *.* LISTEN 0 0 30 40 remoted:123 00000
            tcp6 0 0 fd00::2.4000 fd00:0:0:0:0:0:0:1.5000 ESTABLISHED 10 20 30 40 remoted:123 00000
            """
        XCTAssertEqual(ASNativeRSDPorts(inventory, "fd00::1"), [5000])
        XCTAssertEqual(ASNativeRSDPorts(inventory, "fd00::3"), [6000])
        XCTAssertTrue(ASNativeRSDPorts(inventory, "invalid").isEmpty)
    }

    func testEndpointInventoryRejectsTruncatedMalformedAndAmbiguousEndpoints() {
        func row(_ endpoint: String, _ owner: String = "remoted:1") -> String {
            "tcp6 0 0 fd00::2.1234 \(endpoint) ESTABLISHED 0 0 0 0 \(owner)\n"
        }
        for endpoint in ["fd00::.123", "fd00::1.0", "fd00::1.65536", "fd00::1.-1", "fd00::1.123oops", "*.*"] {
            XCTAssertTrue(ASNativeRSDPorts(row(endpoint), "fd00::1").isEmpty)
        }
        XCTAssertTrue(ASNativeRSDPorts(row("fd00::1.123", "remoted:bad"), "fd00::1").isEmpty)
        // Caller must reject count != 1; never select the first of ambiguous endpoints.
        XCTAssertEqual(ASNativeRSDPorts(row("fd00::1.123") + row("fd00::1.124"), "fd00::1"), [123, 124])
    }

    func testEndpointInventoryRequiresRecentRegularFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("inventory")
        try Data("netstat-output".utf8).write(to: file)
        let now = Date()
        XCTAssertEqual(try NativeEndpointInventory.read(path: file.path, now: now), "netstat-output")
        XCTAssertThrowsError(
            try NativeEndpointInventory.read(path: file.path, now: now.addingTimeInterval(31)))
        XCTAssertThrowsError(
            try NativeEndpointInventory.read(path: file.path, now: now.addingTimeInterval(-1)))
        XCTAssertThrowsError(try NativeEndpointInventory.read(path: directory.path))
        XCTAssertNil(try NativeEndpointInventory.read(path: nil))
    }
}
