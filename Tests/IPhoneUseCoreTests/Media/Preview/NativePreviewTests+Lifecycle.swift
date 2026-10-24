import XCTest
import CoreImage
@testable import IPhoneUseCore

extension NativePreviewTests {
    func testBindingGenerationRejectsPreviousFrameAndGestureRequests() throws {
        let preview = try NativePreview(port: 0)
        defer { preview.close() }
        let old = preview.status()["generation"] as? String
        XCTAssertNotNil(old)
        XCTAssertFalse(old?.contains(preview.token) ?? true, "Generation must not disclose source capability")
        preview.suspend("source replaced")
        XCTAssertNotEqual(preview.status()["generation"] as? String, old)
        for resource in ["frame", "gestures", "bezel"] {
            let url = try XCTUnwrap(URL(string: preview.url + resource + "?generation=" + (old ?? "")))
            XCTAssertEqual(try get(url).0, 409)
        }
    }

    func testOccupiedPortFailsPromptlyAndRetryKeepsLoopbackProtection() throws {
        let occupied = try NativePreview(port: 0)
        defer { occupied.close() }
        let port = UInt16(try XCTUnwrap(occupied.status()["port"] as? Int))
        let started = Date()
        XCTAssertThrowsError(try NativePreview(port: port)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "preview_port_in_use")
            XCTAssertTrue(String(describing: $0).contains("--port"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertEqual(try get(URL(string: occupied.url)!).0, 200, "The occupied listener must remain usable")
        let replacement = try NativePreview(port: 0)
        defer { replacement.close() }
        XCTAssertNotEqual(replacement.status()["port"] as? Int, Int(port))
        XCTAssertEqual(try get(URL(string: replacement.url)!, origin: "http://127.0.0.1:\(port)").0, 403)
        XCTAssertEqual(try get(URL(string: replacement.url)!, host: "127.0.0.1:\(port)").0, 403)
    }

    func testExplicitPortMismatchPreservesExistingPreviewAndPortCanBeRebound() throws {
        let first = try NativePreview(port: 0)
        defer { first.close() }
        let port = UInt16(try XCTUnwrap(first.status()["port"] as? Int))
        XCTAssertEqual(try first.status(for: .init(port: port, explicitPort: true))["url"] as? String, first.url)
        XCTAssertEqual(try first.status(for: .init())["url"] as? String, first.url)
        XCTAssertThrowsError(try first.status(for: .init(port: port == 65535 ? 8765 : port + 1, explicitPort: true))) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "preview_already_running")
        }
        XCTAssertEqual(try get(URL(string: first.url)!).0, 200)
        first.close()
        let restarted = try NativePreview(port: port)
        defer { restarted.close() }
        XCTAssertEqual(restarted.status()["port"] as? Int, Int(port))
        XCTAssertNotEqual(restarted.url, first.url, "Reusing a port must not reuse the previous capability token")
        XCTAssertEqual(try get(URL(string: first.url)!).0, 404)
        XCTAssertEqual(try get(URL(string: restarted.url)!).0, 200)
    }

    func testLoopbackTokenReadOnlyAndClose() throws {
        let preview = try NativePreview(port: 0, device: .init(productType: "iPhone13,3", name: "iPhone 12 Pro"))
        defer { preview.close() }
        let url = try XCTUnwrap(URL(string: preview.url))
        XCTAssertEqual(url.host, "127.0.0.1")
        let page = try get(url)
        XCTAssertEqual(page.0, 200)
        XCTAssertTrue((try XCTUnwrap(String(data: page.1, encoding: .utf8))).contains("id=\"device-name\""))
        XCTAssertTrue((try XCTUnwrap(String(data: page.1, encoding: .utf8))).contains("href=\"favicon.png\""))
        let favicon = try get(url.appendingPathComponent("favicon.png"))
        XCTAssertEqual(favicon.0, 200)
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(favicon.1, try Data(contentsOf: root.appendingPathComponent("assets/brand/favicon-64.png")))
        XCTAssertEqual(try get(url.deletingLastPathComponent().appendingPathComponent("favicon.png")).0, 404)
        let stateResponse = try get(url.appendingPathComponent("state"))
        XCTAssertEqual(stateResponse.0, 200)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: stateResponse.1) as? [String: Any])
        let timing = try XCTUnwrap(state["timing"] as? [String: Any])
        XCTAssertEqual(timing["stageTiming"] as? String, "combined")
        XCTAssertTrue(timing["maxConversionMs"] is NSNull, "Fused export cannot measure conversion separately")
        XCTAssertTrue(timing["maxCompressionMs"] is NSNull, "Unavailable stage timings must not look like zero work")
        let gestures = try get(url.appendingPathComponent("gestures"))
        XCTAssertEqual(gestures.0, 200)
        let events = try XCTUnwrap(JSONSerialization.jsonObject(with: gestures.1) as? [String: Any])
        XCTAssertEqual(events["sequence"] as? Int, 0)
        XCTAssertEqual((events["events"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(try get(url.deletingLastPathComponent().appendingPathComponent("gestures")).0, 404)
        XCTAssertEqual(try get(url.appendingPathComponent("gestures"), origin: "https://foreign.example").0, 403)
        XCTAssertEqual(try get(url.appendingPathComponent("gestures"), host: "foreign.example").0, 403)
        XCTAssertEqual(try get(url.appendingPathComponent("frame")).0, 503)
        XCTAssertEqual(try get(url.deletingLastPathComponent()).0, 404)
        XCTAssertEqual(try get(url, host: "foreign.example").0, 403)
        XCTAssertEqual(try get(url, origin: "https://foreign.example").0, 403)
        XCTAssertEqual(try get(url.appendingPathComponent("tap")).0, 404)
        let asset = try get(url.appendingPathComponent("bezel"))
        XCTAssertEqual(asset.0, 200)
        XCTAssertNotNil(CGImageSourceCreateWithData(asset.1 as CFData, nil))
        XCTAssertEqual(try get(url.deletingLastPathComponent().appendingPathComponent("bezel")).0, 404)
        XCTAssertEqual(try get(url.appendingPathComponent("bezel"), origin: "https://foreign.example").0, 403)
        XCTAssertEqual(try get(url.appendingPathComponent("bezel/unknown")).0, 404)
        preview.close()
        preview.close()
        let stopped = preview.status()
        XCTAssertEqual(stopped["state"] as? String, "stopped")
        XCTAssertEqual(stopped["device"] as? NSDictionary, state["device"] as? NSDictionary)
        XCTAssertEqual(stopped["bezel"] as? NSDictionary, state["bezel"] as? NSDictionary)
        XCTAssertThrowsError(try get(url))
    }

    func testArtworkLookupIsIndependentOfWorkingDirectoryAndRelocatable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("libexec/iphone-use/preview")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data().write(to: assets.appendingPathComponent("catalog.json"))
        XCTAssertEqual(
            NativePreviewPage.assetDirectory(executable: root.appendingPathComponent("bin/iphone-use"))?.path,
            assets.path)
        XCTAssertEqual(
            NativePreviewPage.assetDirectory(
                executable: root.appendingPathComponent(".build/arm64-apple-macosx/release/iphone-use")),
            root.appendingPathComponent("assets/preview"))
        XCTAssertNil(
            NativePreviewPage.assetDirectory(executable: root.appendingPathComponent("isolated/bin/iphone-use")))
    }

    func testExactProductTypeSelectsEveryPackagedModelAndNeverGuessesFromName() throws {
        let directory = try XCTUnwrap(NativePreviewPage.assetDirectory())
        let catalog = try JSONDecoder().decode(
            NativePreviewBezel.Catalog.self, from: Data(contentsOf: directory.appendingPathComponent("catalog.json")))
        XCTAssertEqual(catalog.models.count, 23)
        for (productType, profile) in catalog.models {
            let device = NativePreviewDevice(details: [
                "hardwareProperties": ["productType": productType, "marketingName": profile.name]
            ])
            let selected = try XCTUnwrap(NativePreviewBezel.load(device: device))
            XCTAssertEqual(selected.profile.file, profile.file)
        }
        let first = try XCTUnwrap(NativePreviewBezel.load(device: .init(productType: "iPhone13,2", name: nil)))
        let pro = try XCTUnwrap(NativePreviewBezel.load(device: .init(productType: "iPhone13,3", name: nil)))
        XCTAssertNotEqual(first.profile.file, pro.profile.file, "Same screen dimensions do not imply the same model")
        for productType: String? in [nil, "iPhone99,1", "iphone13,3", " iPhone13,3", "iPhone18,1", "iPhone19,2"] {
            let preview = try NativePreview(port: 0, device: .init(productType: productType, name: "iPhone 12 Pro"))
            defer { preview.close() }
            XCTAssertTrue(preview.status()["bezel"] is NSNull)
            XCTAssertEqual(try get(URL(string: preview.url + "bezel")!).0, 404)
        }
    }

    func testMissingOrTamperedArtworkAndInvalidCatalogFallBackWithoutCrashing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let device = NativePreviewDevice(productType: "iPhone13,3", name: nil)
        XCTAssertNil(NativePreviewBezel.load(device: device, directory: directory))
        let installed = try XCTUnwrap(NativePreviewPage.assetDirectory())
        let data = try Data(contentsOf: installed.appendingPathComponent("catalog.json"))
        try data.write(to: directory.appendingPathComponent("catalog.json"))
        XCTAssertNil(NativePreviewBezel.load(device: device, directory: directory))
        try Data("corrupted".utf8).write(to: directory.appendingPathComponent("iphone-12-pro-portrait.png"))
        XCTAssertNil(NativePreviewBezel.load(device: device, directory: directory))
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("catalog.json"))
        XCTAssertNil(NativePreviewBezel.load(device: device, directory: directory))
    }

    func testPreviewJPEGHasNativeCropAndOrientationWithoutChangingPixels() throws {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 48, 64, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for row in 0..<64 {
            for column in 0..<48 {
                let pixelIndex = base + row * stride + column * 4
                pixelIndex[0] = 0
                pixelIndex[1] = (column < 32 && row < 48) ? 200 : 0
                pixelIndex[2] = 0
                pixelIndex[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let frame = NativeVideoSnapshot.Frame(
            image: NativeDecodedVideoFrame(pixels: buffer, nativeWidth: 32, nativeHeight: 48), firstPacketAt: 1,
            completedAt: 2, timestamp: 1)
        for rotation in ["rot0", "rot90", "rot270"] {
            let display = try NativeDisplay([
                "backlightState": "activeOn",
                "displays": [
                    [
                        "primary": true, "displayId": 1, "bounds": [[0, 0], [32, 48]], "pointScale": 1,
                        "currentOrientation": rotation, "nativeOrientation": "rot0"
                    ]
                ]
            ])
            let data = try NativePreview.encode(
                frame, display: display, context: CIContext(options: [.useSoftwareRenderer: true]))
            let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(image, 0, nil))
            XCTAssertEqual(decoded.width, rotation == "rot0" ? 32 : 48)
            XCTAssertEqual(decoded.height, rotation == "rot0" ? 48 : 32)
            // Check the materialized RGB path as well as its dimensions. The
            // native rectangle is green; decoded padding is black.
            let rgba = try rgbaPixels(decoded)
            for offset in [0, (decoded.width * decoded.height / 2) * 4, rgba.count - 4] {
                XCTAssertLessThan(rgba[offset], 20)
                XCTAssertGreaterThan(rgba[offset + 1], 180)
                XCTAssertLessThan(rgba[offset + 2], 20)
            }
        }
        XCTAssertEqual(frame.timestamp, 1)
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 48)
    }
}
