import Foundation
import CoreGraphics
import ImageIO
import AppleNativeBridge

struct NativeDisplay: Equatable {
    let id: UInt64
    let pixelWidth: Double
    let pixelHeight: Double
    let scale: Double
    let rotation: String
    let nativeRotation: String
    let backlightOn: Bool
    var screen: ScreenRect { ScreenRect(CGRect(x: 0, y: 0, width: pixelWidth / scale, height: pixelHeight / scale)) }
    var context: ScreenContext {
        let orientation = ["rot0": 1, "rot90": 3, "rot180": 2, "rot270": 4][rotation] ?? 0
        // Native screenshots have no keyboard/AX count; this placeholder is only for grid
        // comparison. keyboardState is explicitly unknown in the observation metadata.
        return ScreenContext(screen: screen, scope: screen, orientation: orientation, keyboardCount: 0)
    }
    init(_ result: [String: Any]) throws {
        guard let displays = result["displays"] as? [[String: Any]] else { throw SomaError("native_display_unavailable", "Display list missing") }
        let primary = displays.filter { $0["primary"] as? Bool == true }
        guard primary.count == 1, let value = primary.first,
              let id = value["displayId"] as? NSNumber, id.uint64Value > 0,
              let bounds = value["bounds"] as? [[NSNumber]], bounds.count == 2, bounds.allSatisfy({ $0.count == 2 }),
              bounds[0].map(\.doubleValue) == [0, 0], bounds[1].allSatisfy({ $0.doubleValue.isFinite && $0.doubleValue > 0 && $0.doubleValue <= 16384 }),
              let scale = value["pointScale"] as? NSNumber, scale.doubleValue.isFinite, scale.doubleValue >= 1,
              let rotation = value["currentOrientation"] as? String, ["rot0", "rot90", "rot180", "rot270"].contains(rotation),
              let native = value["nativeOrientation"] as? String else { throw SomaError("native_display_unavailable", "Unknown primary display geometry") }
        self.id = id.uint64Value; pixelWidth = bounds[1][0].doubleValue; pixelHeight = bounds[1][1].doubleValue; self.scale = scale.doubleValue
        self.rotation = rotation; nativeRotation = native; backlightOn = result["backlightState"] as? String == "activeOn"
    }
}

final class AppleDeviceCLI {
    let device: String
    let cancellation: NativeCancellation
    init(device: String, cancellation: NativeCancellation) { self.device = device; self.cancellation = cancellation }
    func read(_ arguments: [String], trailingArguments: [String] = []) throws -> [String: Any] {
        try cancellation.check()
        return try CoreDevice.read(arguments + ["--device", device], cancelled: { self.cancellation.isCancelled }, trailingArguments: trailingArguments)
    }
    func display() throws -> NativeDisplay { try NativeDisplay(read(["device", "info", "displays"])) }
    func capture(generation: String) throws -> CapturedObservation {
        let started = Date().timeIntervalSince1970
        let monotonic = ProcessInfo.processInfo.systemUptime
        let lock = try read(["device", "info", "lockState"])
        guard lock["passcodeRequired"] as? Bool == false else { throw SomaError("device_locked", "Unlock the iPhone before observing") }
        let before = try display()
        guard before.backlightOn else { throw SomaError("capture_unavailable", "The display backlight is off; wake the iPhone before observing") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsoma-screen-\(UUID().uuidString)")
        try SessionPaths.secureDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("screen.png")
        _ = try read(["device", "capture", "screenshot", "--destination", destination.path])
        let after = try display()
        let finalLock = try read(["device", "info", "lockState"])
        guard finalLock["passcodeRequired"] as? Bool == false else { throw SomaError("device_locked", "Device locked during capture") }
        guard before == after, after.backlightOn else { throw SomaError("capture_context_changed", "Display changed during screenshot acquisition") }
        let png = try Data(contentsOf: destination)
        let fingerprint = try FrameFingerprint(png: png)
        guard fingerprint.width == Int(after.pixelWidth), fingerprint.height == Int(after.pixelHeight) else {
            throw SomaError("invalid_image", "Screenshot dimensions disagree with the current display")
        }
        let image = try ScreenImage(png: png)
        let samples = try image.rgb(rect: after.screen, screen: after.screen, columns: 32, rows: 64)
        guard samples.contains(where: { $0 > 8 }) else { throw SomaError("capture_unavailable", "Screenshot is black or unavailable") }
        return CapturedObservation(nodes: [], metadata: [
            "backend": "apple-native", "deviceID": device, "sessionGeneration": generation,
            "captureID": UUID().uuidString, "captureStartedAt": started, "captureCompletedAt": Date().timeIntervalSince1970,
            "captureStartedUptime": monotonic, "screenshotCapturedAt": Date().timeIntervalSince1970,
            "screenshotWidth": fingerprint.width, "screenshotHeight": fingerprint.height, "frameHash": fingerprint.hash,
            "displayID": after.id, "displayRotation": after.rotation, "nativeRotation": after.nativeRotation,
            "coordinateSpace": "screen_points", "pointScale": after.scale,
            "imageTransform": ["cropOriginPixels": [0, 0], "resizeScale": 1, "pixelsPerPoint": after.scale],
            "screenFrame": try jsonObject(JSONEncoder().encode(after.screen)),
            "screenContext": try jsonObject(JSONEncoder().encode(after.context)),
            "scope": "screen", "foregroundBundleId": NSNull(), "keyboardState": "unknown",
            "axStatus": "unavailable", "axError": "Native backend uses screenshots; AX is not collected",
            "sourceTruncated": false, "validity": "valid"
        ], screenshot: png)
    }
}

final class AppleDeviceBackend: SessionBackend {
    private let config: HostConfiguration
    private let paths: SessionPaths
    private let cancellation = NativeCancellation()
    private let generation = UUID().uuidString
    private var cli: AppleDeviceCLI?
    private var deviceLock: DeviceLock?
    private var hidTransport: NativeTransport?
    private var mediaTransport: NativeTransport?
    private var hid: NativeHIDAdapter?
    private var media: NativeMediaSession?
    private var tunnel: ASPairedTunnel?
    private var controlError: String?
    private var controlErrorCode: String?
    private var cleanupFacts: [String: Any] = [:]
    private var stopped = false

    private let makeHID: (NativeTransport, NativeCancellation) -> NativeHIDAdapter

    init(config: HostConfiguration, paths: SessionPaths,
         makeHID: @escaping (NativeTransport, NativeCancellation) -> NativeHIDAdapter = {
             NativeHIDAdapter(transport: $0, cancellation: $1)
         }) {
        self.config = config; self.paths = paths; self.makeHID = makeHID
    }
    func start() throws -> [String: Any] {
        let details = try CoreDevice.read(["device", "info", "details", "--device", config.device])
        guard let hardware = details["hardwareProperties"] as? [String: Any], hardware["reality"] as? String == "physical",
              let udid = hardware["udid"] as? String,
              let properties = details["deviceProperties"] as? [String: Any], properties["developerModeStatus"] as? String == "enabled",
              let connection = details["connectionProperties"] as? [String: Any], connection["pairingState"] as? String == "paired",
              let address = connection["tunnelIPAddress"] as? String,
              let identifier = details["identifier"] as? String else {
            throw SomaError("native_device_unavailable", "Need a paired physical iPhone with Developer Mode and a CoreDevice tunnel")
        }
        deviceLock = try DeviceLock(root: paths.directory.deletingLastPathComponent(), device: udid)
        cli = AppleDeviceCLI(device: udid, cancellation: cancellation)
        do {
            guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
                  (properties["osVersionNumber"] as? String)?.hasPrefix("27.") == true else {
                throw SomaError("native_protocol_unsupported", "The experimental control adapter targets macOS 27 and iOS 27 only")
            }
            let inventory = try NativeEndpointInventory.read(path: config.nativeEndpointInventory)
            let paired = try ASPairedTunnel(udid: udid, deviceIdentifier: identifier, endpointInventory: inventory)
            tunnel = paired
            try cancellation.check()
            guard paired.deviceAddress == address else { throw SomaError("native_device_mismatch", "Paired tunnel changed since device discovery; connect again explicitly") }
            let displayTransport = try AppleServiceTransport(tunnel: paired, service: "com.apple.coredevice.displayservice")
            mediaTransport = displayTransport
            let inputTransport = try AppleServiceTransport(tunnel: paired, service: "com.apple.coredevice.hid.universalhidservice")
            hidTransport = inputTransport
            let display = try cli!.display()
            let infoURL = URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/Info.plist")
            let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: infoURL), format: nil) as? [String: Any]
            guard let version = info?["CFBundleVersion"] as? String else { throw SomaError("native_version_unsupported", "Installed CoreDevice version unavailable") }
            let receiver = try NativeRTPReceiver(deviceAddress: address)
            let session = NativeMediaSession(client: NativeFeatureClient(transport: displayTransport, deviceIdentifier: identifier, version: version), receiver: receiver)
            media = session
            let negotiator = try ASMediaNegotiator(error: ())
            try cancellation.check()
            try session.start(displayID: display.id, deviceAddress: address, offer: negotiator.offer) { try negotiator.acceptAnswer($0) }
            let input = makeHID(inputTransport, cancellation)
            try input.prepare(); hid = input
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while session.health()["healthy"] as? Bool != true, ProcessInfo.processInfo.systemUptime < deadline {
                try cancellation.check(); Thread.sleep(forTimeInterval: 0.05)
            }
            guard session.health()["healthy"] as? Bool == true else { throw SomaError("native_media_unhealthy", "Media started but no healthy RTP/RTCP flow was observed") }
        } catch {
            controlError = (error as NSError).userInfo[NSLocalizedDescriptionKey] as? String ?? String(describing: error)
            controlErrorCode = (error as? SomaError)?.code ?? (error as NSError).userInfo["somaCode"] as? String ?? "native_control_unavailable"
            cleanupFacts = media?.close() ?? ["mediaStopAcknowledged": true]
            mediaTransport?.cancel(); hidTransport?.cancel(); hid = nil
            cleanupFacts["tunnelReleaseAcknowledged"] = tunnel?.close() ?? ((error as NSError).userInfo["tunnelReleaseAcknowledged"] as? Bool ?? true)
            tunnel = nil
            // Explicit observation-only readiness, no Runner fallback or silent input support claim.
            try saveJSON(["controlAvailable": false, "error": controlError!, "errorCode": controlErrorCode!,
                          "cleanup": cleanupFacts],
                         to: paths.directory.appendingPathComponent("native-control.json"))
        }
        return try status()
    }
    func status() throws -> [String: Any] {
        guard !stopped else { throw SomaError("backend_unavailable", "Native session closed") }
        let healthy = media?.health()["healthy"] as? Bool == true
        return ["backend": "apple-native", "sessionGeneration": generation, "deviceID": cli?.device ?? config.device,
                "capabilities": ["screenshot": true, "tap": hid?.isAvailable == true && healthy, "ax": false, "swipe": false, "text": false],
                "controlAvailable": hid?.isAvailable == true && healthy, "controlError": controlError as Any? ?? NSNull(),
                "controlErrorCode": controlErrorCode as Any? ?? NSNull(),
                "media": media?.health() ?? [:], "runnerStarted": false, "serviceTransport": config.nativeEndpointInventory == nil ? "apple-coredevice-service-socket" : "apple-paired-tunnel",
                "endpointDiscovery": config.nativeEndpointInventory == nil ? "apple-coredevice-service-socket" : "supplied-apple-netstat-inventory",
                "validation": "experimental; inspect the after-observation to verify each input"]
    }
    func apps() throws -> AppCatalog {
        guard let cli else { throw SomaError("backend_unavailable", "Native backend not started") }
        return try AppCatalog(cli.read(["device", "info", "apps", "--include-all-apps"]))
    }
    func open(bundle: String) throws -> [String: Any] {
        try apps().requireInstalled(bundle)
        guard let cli else { throw SomaError("backend_unavailable", "Native backend not started") }
        do {
            let result = try cli.read(["device", "process", "launch", "--activate"], trailingArguments: [bundle])
            return ["bundleId": bundle, "transportStatus": "acknowledged", "verificationStatus": "not_checked",
                    "foregroundConfirmed": false, "launch": result]
        } catch {
            throw ActionFailure(code: "native_launch_uncertain", description: "Launch result is uncertain: \(error)",
                                possiblyExecuted: true, requiresObservation: true)
        }
    }
    func observe() throws -> CapturedObservation {
        guard let cli else { throw SomaError("backend_unavailable", "Native backend not started") }
        return try cli.capture(generation: generation)
    }
    func perform(_ action: DeviceAction, target: ObservedTarget) throws -> [String: Any] {
        guard action.kind == "tap", action.coordinate else { throw SomaError("native_action_unsupported", "Native backend currently implements screenshot-coordinate tap only") }
        guard let hid, hid.isAvailable, let media, media.health()["healthy"] as? Bool == true else {
            throw SomaError("native_control_unavailable", controlError ?? "Native media/HID session is not healthy")
        }
        guard target.context["deviceID"] as? String == cli?.device,
              target.context["sessionGeneration"] as? String == generation,
              let captured = target.context["captureStartedUptime"] as? Double,
              ProcessInfo.processInfo.systemUptime - captured <= 30,
              let gesture = target.gesture else {
            throw ActionFailure(code: "stale_observation", description: "Observe this device/session again before input", possiblyExecuted: false, requiresObservation: true)
        }
        // Rotation formulas have host tests but lack device acceptance. Fail closed for now.
        guard target.context["displayRotation"] as? String == "rot0", target.context["nativeRotation"] as? String == "rot0" else {
            throw SomaError("native_orientation_unsupported", "Native HID currently requires the original portrait orientation")
        }
        let before: CapturedObservation
        let check: ScreenGuard.Check
        do {
            before = try observe()
            guard before.metadata["displayID"] as? UInt64 == target.context["displayID"] as? UInt64,
                  let raw = before.metadata["screenContext"] as? [String: Any] else { throw ScreenGuard.Failure.contextChanged }
            let context = try JSONDecoder().decode(ScreenContext.self, from: jsonData(raw))
            check = try gesture.screenGuard.check(png: before.screenshot, context: context)
            guard check.accepted else { throw SomaError("screen_changed", "Screen guard rejected changed pixels") }
        } catch {
            throw ActionFailure(code: "stale_observation", description: "Pre-input capture/guard failed: \(error)", possiblyExecuted: false, requiresObservation: true)
        }
        try cancellation.check()
        guard ProcessInfo.processInfo.systemUptime - captured <= 30 else {
            throw ActionFailure(code: "stale_observation", description: "Observation expired during pre-input capture", possiblyExecuted: false, requiresObservation: true)
        }
        guard media.health()["healthy"] as? Bool == true else { throw SomaError("native_media_unhealthy", "Media stopped before touch") }
        let point = try NativeCoordinateMapper.map(gesture.start, screen: gesture.screenGuard.context.screen, rotation: "rot0")
        var result = try hid.tap(point)
        result["sourceObservationID"] = action.reference.observation
        result["screenGuard"] = check.result
        return result
    }
    func cancelCurrent() { cancellation.cancel() }
    func stop() -> [String: Any] {
        if stopped { return cleanupFacts }
        stopped = true; cancellation.cancel()
        var result = hid?.release() ?? ["releaseRequired": false, "releaseUncertain": false]
        result.merge(media?.close() ?? cleanupFacts) { _, new in new }
        mediaTransport?.cancel(); hidTransport?.cancel(); hid = nil; media = nil
        result["tunnelReleaseAcknowledged"] = tunnel?.close() ?? (cleanupFacts["tunnelReleaseAcknowledged"] as? Bool ?? true)
        tunnel = nil
        deviceLock = nil
        result["connectionsClosed"] = true
        result["shutdownAcknowledged"] = result["mediaStopAcknowledged"] as? Bool != false && result["releaseUncertain"] as? Bool != true
            && result["tunnelReleaseAcknowledged"] as? Bool == true
        result["backendStopped"] = true
        cleanupFacts = result
        return result
    }
}

enum NativeEndpointInventory {
    static func read(path: String?, now: Date = Date()) throws -> String? {
        guard let path else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let modified = attributes[.modificationDate] as? Date,
              (0...30).contains(now.timeIntervalSince(modified)),
              let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 16 * 1024 * 1024 else {
            throw SomaError("native_endpoint_inventory_invalid", "Provide a nonempty, regular Apple netstat -anvl -p tcp output file captured within 30 seconds")
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }
}
