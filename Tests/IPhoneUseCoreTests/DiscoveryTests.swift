import XCTest
@testable import IPhoneUseCore

final class DiscoveryTests: XCTestCase {
    func testCommandDeadlineIsARecognizedTimeoutWithoutLosingOriginalEvidence() {
        for seconds in ["5.0", "20"] {
            let raw = "ERROR: Command timeout of \(seconds) seconds exceeded. Assuming command got stuck and aborting."
            let error = CoreDevice.commandFailure(["device", "info", "lockState"], exitCode: 2, output: raw)
            XCTAssertEqual(error.code, "coredevice_timeout")
            XCTAssertTrue(error.description.contains(raw))
            XCTAssertTrue(error.description.contains("device info lockState"))
        }
        XCTAssertEqual(CoreDevice.commandFailure(["device", "info", "lockState"], exitCode: 2,
            output: "Unknown timeout while connecting").code, "coredevice_failed")
    }

    func testToolchainFailuresProvideActionableGuidanceWithoutDiscardingAppleError() {
        let cases = [
            "xcrun: error: invalid active developer path (/Library/Developer/CommandLineTools)",
            "xcrun: error: invalid DEVELOPER_DIR path: invalid developer directory '/missing'",
            "xcrun: error: missing DEVELOPER_DIR path: /tmp/missing Xcode",
            "xcrun: error: unable to find utility \"devicectl\", not a developer tool or in PATH",
            "xcode-select: error: tool 'devicectl' requires Xcode, but active developer directory is a command line tools instance"
        ]
        for raw in cases {
            let error = CoreDevice.commandFailure(["list", "devices"], exitCode: 72, output: raw)
            XCTAssertEqual(error.code, "xcode_unavailable")
            XCTAssertTrue(error.description.contains(raw))
            XCTAssertTrue(error.description.contains("DEVELOPER_DIR"))
            XCTAssertTrue(error.description.contains("does not require Runner setup"))
        }
        let raw = "You have not agreed to the Xcode license agreements."
        let license = CoreDevice.commandFailure(["list", "devices"], exitCode: 69, output: raw)
        XCTAssertEqual(license.code, "xcode_license_required")
        XCTAssertTrue(license.description.contains(raw))
        XCTAssertEqual(CoreDevice.commandFailure(["list", "devices"], exitCode: 1,
            output: "Unknown license transport error").code, "coredevice_failed")
    }

    func testNativePrerequisiteErrorsDistinguishKnownFailuresFromMissingFacts() {
        let unpaired = CoreDevice.nativeDeviceUnavailable(["connectionProperties": ["pairingState": "unpaired"]])
        XCTAssertEqual(unpaired.code, "device_not_paired")
        XCTAssertTrue(unpaired.description.contains("Trust This Computer"))
        let disabled = CoreDevice.nativeDeviceUnavailable(["deviceProperties": ["developerModeStatus": "disabled"]])
        XCTAssertEqual(disabled.code, "developer_mode_disabled")
        XCTAssertTrue(disabled.description.contains("Privacy & Security"))
        let unknownCases: [[String: Any]] = [[:], ["connectionProperties": ["pairingState": "unknown"]],
            ["deviceProperties": ["developerModeStatus": "unknown"]],
            ["connectionProperties": ["pairingState": "paired"], "deviceProperties": ["developerModeStatus": "enabled"]]]
        for details in unknownCases {
            XCTAssertEqual(CoreDevice.nativeDeviceUnavailable(details).code, "native_device_unavailable")
        }
    }

    func testInitializationTimeoutPreservesEvidenceAndSuggestsPermissionComparison() {
        let raw = "ERROR: Timed out waiting for CoreDeviceService to fully initialize. This is likely a bug in CoreDevice. (com.apple.coredevice.devicectl error 1 (0x01))"
        let error = CoreDevice.commandFailure(["list", "devices"], exitCode: 1, output: raw)
        XCTAssertEqual(error.code, "coredevice_initialization_timeout")
        XCTAssertTrue(error.description.contains("list devices"))
        XCTAssertTrue(error.description.contains(raw))
        XCTAssertTrue(error.description.contains("approved host permissions"))
        XCTAssertTrue(error.description.contains("does not establish"))
    }

    func testPermissionDenialIsDistinctFromUnknownCoreDeviceFailure() {
        let denied = CoreDevice.commandFailure(["device", "info", "details", "--device", "test"],
                                               exitCode: 1, output: "Operation not permitted")
        XCTAssertEqual(denied.code, "coredevice_access_denied")
        XCTAssertTrue(denied.description.contains("device info details"))
        XCTAssertTrue(denied.description.contains("Operation not permitted"))
        let other = CoreDevice.commandFailure(["device", "info", "apps"], exitCode: 70, output: "Device not found")
        XCTAssertEqual(other.code, "coredevice_failed")
        XCTAssertTrue(other.description.contains("70"))
        XCTAssertTrue(other.description.contains("Device not found"))
        XCTAssertFalse(other.description.contains("approved host permissions"))
    }

    func testFailureClassificationUsesFullLogButBoundsReturnedEvidence() {
        let prefix = "Timed out waiting for CoreDeviceService to fully initialize.\n"
        let output = prefix + String(repeating: "diagnostic detail\n", count: 500) + "last error line"
        let error = CoreDevice.commandFailure(["device", "info", "lockState"], exitCode: 1, output: output)
        XCTAssertEqual(error.code, "coredevice_initialization_timeout")
        XCTAssertTrue(error.description.contains("device info lockState"))
        XCTAssertTrue(error.description.hasSuffix(String(output.suffix(4000))))
        XCTAssertLessThan(error.description.count, 5000)
        XCTAssertEqual(CoreDevice.commandFailure(["list", "devices"], exitCode: 1,
            output: "Timed out connecting to a device").code, "coredevice_failed")
        XCTAssertEqual(CoreDevice.commandFailure(["list", "devices"], exitCode: 1,
            output: "PERMISSION DENIED").code, "coredevice_access_denied")
    }

    func testDeviceIDsAndConnectionFactsDoNotInventReadiness() throws {
        let result = try DeviceDiscovery.devices(from: ["devices": [
            ["identifier": "core-z", "hardwareProperties": ["udid": "udid-z", "platform": "iOS", "deviceType": "iPhone"],
             "deviceProperties": ["name": "Phone", "osVersionNumber": "26.6"],
             "connectionProperties": ["transportType": "wired", "tunnelState": "disconnected", "pairingState": "paired"]],
            ["identifier": "core-a"]
        ]])
        XCTAssertEqual(result.map { $0["id"] as! String }, ["core-a", "udid-z"])
        XCTAssertTrue(result[0]["osVersion"] is NSNull)
        XCTAssertTrue((result[0]["connection"] as! [String: Any])["transport"] is NSNull)
        XCTAssertEqual((result[1]["connection"] as! [String: Any])["tunnelState"] as? String, "disconnected")
        XCTAssertNil(result[1]["ready"])
        XCTAssertNoThrow(try jsonData(["devices": result]))
    }

    func testMalformedDiscoveryIsNotAnEmptyInventory() throws {
        XCTAssertThrowsError(try DeviceDiscovery.devices(from: [:]))
        XCTAssertThrowsError(try DeviceDiscovery.devices(from: ["devices": [[:]]]))
        XCTAssertThrowsError(try AppCatalog([:]))
        XCTAssertThrowsError(try AppCatalog(["apps": [["name": "Missing ID"]]]))
        XCTAssertTrue(try DeviceDiscovery.devices(from: ["devices": []]).isEmpty)
        XCTAssertEqual(try AppCatalog(["apps": []]).page(query: nil, offset: 0)["total"] as? Int, 0)
    }

    func testAppPagesAreBoundedSortedAndFilteredWithoutLosingUnknownNames() throws {
        let rows: [[String: Any]] = (0..<53).reversed().map {
            ["bundleIdentifier": String(format: "com.example.app%02d", $0), "name": "示例 App \($0)"]
        } + [["bundleIdentifier": "org.example.unnamed"]]
        let catalog = try AppCatalog(["apps": rows])
        let first = try catalog.page(query: nil, offset: 0)
        let second = try catalog.page(query: nil, offset: first["nextOffset"] as! Int)
        let apps = (first["apps"] as! [[String: Any]]) + (second["apps"] as! [[String: Any]])
        XCTAssertEqual((first["apps"] as! [[String: Any]]).count, 50)
        XCTAssertEqual(first["total"] as? Int, 54)
        XCTAssertEqual(apps.map { $0["bundleId"] as! String }, rows.compactMap { $0["bundleIdentifier"] as? String }.sorted())
        XCTAssertTrue(apps.last?["name"] is NSNull)
        XCTAssertTrue(second["nextOffset"] is NSNull)
        XCTAssertEqual(try catalog.page(query: "COM.EXAMPLE.APP", offset: 0)["total"] as? Int, 53)
        XCTAssertEqual(try catalog.page(query: "示例 App 52", offset: 0)["total"] as? Int, 1)
        XCTAssertEqual(try catalog.page(query: "absent", offset: 0)["total"] as? Int, 0)
        XCTAssertEqual((try catalog.page(query: nil, offset: 54)["apps"] as! [[String: Any]]).count, 0)
        XCTAssertThrowsError(try catalog.page(query: nil, offset: 55))
        XCTAssertThrowsError(try catalog.page(query: nil, offset: -1))
    }

    func testInstalledCheckUsesExactBundleIDWithoutAnAppWhitelist() throws {
        let catalog = try AppCatalog(["apps": [["bundleIdentifier": "org.example.thirdparty", "name": "Third Party"]]])
        XCTAssertNoThrow(try catalog.requireInstalled("org.example.thirdparty"))
        for bundle in ["Third Party", "org.example", "ORG.EXAMPLE.THIRDPARTY", "com.apple.calculator"] {
            XCTAssertThrowsError(try catalog.requireInstalled(bundle)) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, "app_not_installed")
            }
        }
    }
}
