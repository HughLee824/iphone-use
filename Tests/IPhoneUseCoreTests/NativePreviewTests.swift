import XCTest
import CoreImage
@testable import IPhoneUseCore

final class NativePreviewTests: XCTestCase {
    private func get(_ url: URL, host: String? = nil, origin: String? = nil) throws -> (Int, Data) {
        let done = expectation(description: "HTTP")
        var response: HTTPURLResponse?, bytes = Data(), failure: Error?
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData); request.timeoutInterval = 3
        if let host { request.setValue(host, forHTTPHeaderField: "Host") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        URLSession.shared.dataTask(with: request) { data, result, error in
            bytes = data ?? Data(); response = result as? HTTPURLResponse; failure = error; done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        if let failure { throw failure }
        return (try XCTUnwrap(response).statusCode, bytes)
    }

    func testLoopbackTokenReadOnlyAndClose() throws {
        let preview = try NativePreview(device: .init(productType: "iPhone13,3", name: "iPhone 12 Pro")); defer { preview.close() }
        let url = try XCTUnwrap(URL(string: preview.url))
        XCTAssertEqual(url.host, "127.0.0.1")
        let page = try get(url)
        XCTAssertEqual(page.0, 200)
        XCTAssertTrue(String(decoding: page.1, as: UTF8.self).contains("id=\"device-name\""))
        XCTAssertTrue(String(decoding: page.1, as: UTF8.self).contains("href=\"favicon.png\""))
        let favicon = try get(url.appendingPathComponent("favicon.png"))
        XCTAssertEqual(favicon.0, 200)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(favicon.1, try Data(contentsOf: root.appendingPathComponent("assets/brand/favicon-64.png")))
        XCTAssertEqual(try get(url.deletingLastPathComponent().appendingPathComponent("favicon.png")).0, 404)
        XCTAssertEqual(try get(url.appendingPathComponent("state")).0, 200)
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
        preview.close(); preview.close()
        XCTAssertThrowsError(try get(url))
    }

    func testArtworkLookupIsIndependentOfWorkingDirectoryAndRelocatable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("libexec/iphone-use/preview")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data().write(to: assets.appendingPathComponent("catalog.json"))
        XCTAssertEqual(NativePreviewPage.assetDirectory(executable: root.appendingPathComponent("bin/iphone-use"))?.path, assets.path)
        XCTAssertEqual(NativePreviewPage.assetDirectory(executable: root.appendingPathComponent(".build/arm64-apple-macosx/release/iphone-use")), root.appendingPathComponent("assets/preview"))
        XCTAssertNil(NativePreviewPage.assetDirectory(executable: root.appendingPathComponent("isolated/bin/iphone-use")))
    }

    func testExactProductTypeSelectsEveryPackagedModelAndNeverGuessesFromName() throws {
        let directory = try XCTUnwrap(NativePreviewPage.assetDirectory())
        let catalog = try JSONDecoder().decode(NativePreviewBezel.Catalog.self,
            from: Data(contentsOf: directory.appendingPathComponent("catalog.json")))
        XCTAssertEqual(catalog.models.count, 23)
        for (productType, profile) in catalog.models {
            let device = NativePreviewDevice(details: ["hardwareProperties": ["productType": productType, "marketingName": profile.name]])
            let selected = try XCTUnwrap(NativePreviewBezel.load(device: device))
            XCTAssertEqual(selected.profile.file, profile.file)
        }
        let first = try XCTUnwrap(NativePreviewBezel.load(device: .init(productType: "iPhone13,2", name: nil)))
        let pro = try XCTUnwrap(NativePreviewBezel.load(device: .init(productType: "iPhone13,3", name: nil)))
        XCTAssertNotEqual(first.profile.file, pro.profile.file, "Same screen dimensions do not imply the same model")
        for productType: String? in [nil, "iPhone99,1", "iphone13,3", " iPhone13,3", "iPhone18,1", "iPhone19,2"] {
            let preview = try NativePreview(device: .init(productType: productType, name: "iPhone 12 Pro"))
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
        for y in 0..<64 { for x in 0..<48 {
            let p = base + y * stride + x * 4
            p[0] = 0; p[1] = (x < 32 && y < 48) ? 200 : 0; p[2] = 0; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let frame = NativeVideoSnapshot.Frame(image: NativeDecodedVideoFrame(pixels: buffer, nativeWidth: 32, nativeHeight: 48), firstPacketAt: 1, completedAt: 2, timestamp: 1)
        for rotation in ["rot0", "rot90", "rot270"] {
            let display = try NativeDisplay(["backlightState": "activeOn", "displays": [["primary": true, "displayId": 1,
                "bounds": [[0,0],[32,48]], "pointScale": 1, "currentOrientation": rotation, "nativeOrientation": "rot0"]]])
            let data = try NativePreview.encode(frame, display: display, context: CIContext(options: [.useSoftwareRenderer: true]))
            let image = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(image, 0, nil))
            XCTAssertEqual(decoded.width, rotation == "rot0" ? 32 : 48)
            XCTAssertEqual(decoded.height, rotation == "rot0" ? 48 : 32)
            // Check the materialized RGB path as well as its dimensions. The
            // native rectangle is green; decoded padding is black.
            var rgba = [UInt8](repeating: 0, count: decoded.width * decoded.height * 4)
            try rgba.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: decoded.width,
                    height: decoded.height, bitsPerComponent: 8, bytesPerRow: decoded.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
            }
            for offset in [0, (decoded.width * decoded.height / 2) * 4, rgba.count - 4] {
                XCTAssertLessThan(rgba[offset], 20)
                XCTAssertGreaterThan(rgba[offset + 1], 180)
                XCTAssertLessThan(rgba[offset + 2], 20)
            }
        }
        XCTAssertEqual(frame.timestamp, 1)
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 48)
    }

    func testFractionalPreviewResizeDoesNotIntroduceBrightEdgesOrDecoderPadding() throws {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 1184, 2544, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        let frame = NativeVideoSnapshot.Frame(image: NativeDecodedVideoFrame(pixels: buffer, nativeWidth: 1170,
            nativeHeight: 2532), firstPacketAt: 1, completedAt: 2, timestamp: 1)
        let context = CIContext(options: [.useSoftwareRenderer: true])
        for green: UInt8 in [0, 200] {
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<2544 { for x in 0..<1184 {
                let p = base + y * stride + x * 4
                let native = x < 1170 && y < 2532
                p[0] = native ? 0 : 255; p[1] = native ? green : 0
                p[2] = native ? 0 : 255; p[3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            for rotation in ["rot0", "rot90", "rot270"] {
                let display = try NativeDisplay(["backlightState": "activeOn", "displays": [["primary": true,
                    "displayId": 1, "bounds": [[0, 0], [1170, 2532]], "pointScale": 1,
                    "currentOrientation": rotation, "nativeOrientation": "rot0"]]])
                let data = try NativePreview.encode(frame, display: display, context: context)
                let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(image.width, rotation == "rot0" ? 444 : 960)
                XCTAssertEqual(image.height, rotation == "rot0" ? 960 : 444)
                var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
                try rgba.withUnsafeMutableBytes { bytes in
                    let rgb = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    rgb.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                // Every border pixel: detects fractional alpha, resampling halo,
                // or padding leaking into any edge after either rotation.
                for y in 0..<image.height { for x in 0..<image.width
                    where x == 0 || y == 0 || x == image.width - 1 || y == image.height - 1 {
                    let offset = (y * image.width + x) * 4
                    XCTAssertLessThan(rgba[offset], 15, "red edge: \(rotation), \(x),\(y)")
                    XCTAssertLessThan(abs(Int(rgba[offset + 1]) - Int(green)), 15, "green edge: \(rotation), \(x),\(y)")
                    XCTAssertLessThan(rgba[offset + 2], 15, "blue edge: \(rotation), \(x),\(y)")
                } }
            }
        }
    }

    func testHalfTurnNeedsDistinctAgreementAndDoesNotGuessOnSymmetricFrames() {
        let upright = Data([255,0,0, 0,255,0, 0,0,255, 0,0,0])
        let inverted = Data([0,0,0, 0,0,255, 0,255,0, 255,0,0])
        XCTAssertTrue(NativePreviewOrientation.halfTurnConflict(reference: upright, preview: inverted))
        XCTAssertFalse(NativePreviewOrientation.halfTurnConflict(reference: upright, preview: upright))
        XCTAssertFalse(NativePreviewOrientation.halfTurnConflict(reference: Data(repeating: 0, count: 12), preview: Data(repeating: 0, count: 12)))
        XCTAssertFalse(NativePreviewOrientation.halfTurnConflict(reference: upright, preview: Data(repeating: 127, count: 12)))
        XCTAssertTrue(NativeCaptureChecks.needsOrientationRecovery(IPhoneUseError("native_screenshot_geometry_conflict", "fixture")))
        XCTAssertFalse(NativeCaptureChecks.needsOrientationRecovery(IPhoneUseError("invalid_image", "corrupt PNG")))
    }

    func testWaitingForNextFrameHasBoundedTimeout() throws {
        let preview = try NativePreview(); defer { preview.close() }
        let url = try XCTUnwrap(URL(string: preview.url + "frame?after=0"))
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(try get(url).0, 503)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertGreaterThanOrEqual(elapsed, 0.9)
        XCTAssertLessThan(elapsed, 2.5)
        XCTAssertEqual(preview.status()["maxFPS"] as? Int, 30)
    }

    private func withPreviewReceiver(_ body: (NativeRTPReceiver, (UInt8) -> Void) throws -> Void) throws {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 12, 18, kCVPixelFormatType_32BGRA, nil, &pixels), kCVReturnSuccess)
        let frame = NativeDecodedVideoFrame(pixels: try XCTUnwrap(pixels), nativeWidth: 12, nativeHeight: 18)
        let receiver = try NativeRTPReceiver(deviceAddress: "::1", captureSnapshots: true, makeSnapshots: {
            NativeVideoSnapshot(decode: { _ in frame }, resetDecoder: {})
        })
        defer { receiver.close() }
        let sender = socket(AF_INET6, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(sender, 0)
        defer { Darwin.close(sender) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size); address.sin6_family = sa_family_t(AF_INET6)
        XCTAssertEqual(inet_pton(AF_INET6, "::1", &address.sin6_addr), 1)
        XCTAssertEqual(withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(sender, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
        } }, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        XCTAssertEqual(withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(sender, $0, &length)
        } }, 0)
        try receiver.configure(["SourcePort": UInt16(bigEndian: address.sin6_port), "LocalSSRC": 123, "RemoteSSRC": 456,
            "RTCPEnabled": true, "RTCPSendInterval": 1.0, "SRTPCipherSuite": 0, "RxPayloadType": 100, "TilesPerFrame": 1])
        address.sin6_port = receiver.port.bigEndian
        func send(_ sequence: UInt8) {
            let packet = Data([0x80, 0xe4, 0, sequence, 0, 0, 0, sequence, 0, 0, 0, 123, 40, 1, 1])
            _ = packet.withUnsafeBytes { bytes in withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(sender, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            } }
        }
        try body(receiver, send)
    }

    func testSlowEncodingDoesNotBlockHTTPAndCannotPublishAfterSuspend() throws {
        try withPreviewReceiver { receiver, send in
            let entered = expectation(description: "encoder started"), release = DispatchSemaphore(value: 0)
            let preview = try NativePreview(encodeFrame: { _, _, _ in
                entered.fulfill(); _ = release.wait(timeout: .now() + 5); return .init(data: Data([0xff, 0xd8, 0xff, 0xd9]))
            })
            defer { release.signal(); preview.close() }
            let display = try NativeDisplay(["backlightState": "activeOn", "displays": [["primary": true, "displayId": 1,
                "bounds": [[0,0],[12,18]], "pointScale": 1, "currentOrientation": "rot0", "nativeOrientation": "rot0"]]])
            preview.attach(receiver, display: display)
            send(1)
            wait(for: [entered], timeout: 2)
            let started = ProcessInfo.processInfo.systemUptime
            let response = try get(try XCTUnwrap(URL(string: preview.url + "state")))
            XCTAssertEqual(response.0, 200)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
            preview.suspend("rotation changed")
            release.signal()
            let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                preview.status()["encodingInFlight"] as? Bool == false
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 2), .completed)
            XCTAssertEqual(preview.status()["encodedFrames"] as? Int, 0, "Old binding pixels must not be published")
        }
    }

    func testFreshEncodingBypassesSlowFrameAndLateResultCannotReplaceIt() throws {
        try withPreviewReceiver { receiver, send in
            let entered = expectation(description: "slow encoder started"), release = DispatchSemaphore(value: 0)
            let preview = try NativePreview(encodeFrame: { frame, _, _ in
                if frame.timestamp == 1 { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
                return .init(data: Data([0xff, 0xd8, UInt8(frame.timestamp), 0xff, 0xd9]))
            })
            defer { release.signal(); preview.close() }
            let display = try NativeDisplay(["backlightState": "activeOn", "displays": [["primary": true, "displayId": 1,
                "bounds": [[0,0],[12,18]], "pointScale": 1, "currentOrientation": "rot0", "nativeOrientation": "rot0"]]])
            preview.attach(receiver, display: display); send(1)
            wait(for: [entered], timeout: 2)
            send(2)
            let published = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                preview.status()["encodedFrames"] as? Int == 1
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [published], timeout: 2), .completed, "Fresh output must not wait for the slow slot")
            XCTAssertEqual(preview.status()["inFlightEncodes"] as? Int, 1)
            release.signal()
            let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                preview.status()["encodingInFlight"] as? Bool == false
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 2), .completed)
            XCTAssertEqual(preview.status()["encodedFrames"] as? Int, 1)
            XCTAssertEqual(preview.status()["discardedEncodes"] as? Int, 1)
            let response = try get(try XCTUnwrap(URL(string: preview.url + "frame")))
            XCTAssertEqual(response.0, 200)
            XCTAssertEqual(response.1, Data([0xff, 0xd8, 2, 0xff, 0xd9]))
        }
    }
}
