import Foundation
import Network
import CoreImage
import ImageIO

// Read-only, session-owned browser preview. The browser waits for a single latest
// JPEG, not device screenshots. Encoding and HTTP never run on the device queue.
final class NativePreview {
    struct EncodedJPEG {
        let data: Data
    }
    private let queue = DispatchQueue(label: "iphone-use.preview", qos: .userInitiated)
    private let encoderQueue = DispatchQueue(label: "iphone-use.preview.encode", qos: .userInitiated, attributes: .concurrent)
    private let encodeFrame: (NativeVideoSnapshot.Frame, NativeDisplay, CIContext) throws -> EncodedJPEG
    private let connectionStatus: () -> [String: Any]?
    private var lastSubmittedFrameAt: Double?
    private var discardedEncodes = 0
    private var bindingGeneration = 0
    private let listener: NWListener
    private let token = UUID().uuidString
    // This is a small JPEG, not a full-size video encode. CPU rendering avoids
    // queueing its resize/color conversion behind live video and file decoding.
    private var contexts = (0..<2).map { _ in CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true]) }
    private var timer: DispatchSourceTimer?
    private var waiting: [ObjectIdentifier: (sequence: Int, deadline: Double)] = [:]
    private var waitingGestures: [ObjectIdentifier: (sequence: Int, deadline: Double)] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var receiver: NativeRTPReceiver?
    private var display: NativeDisplay?
    private var device: NativePreviewDevice
    private var bezel: NativePreviewBezel?
    private var jpegRotation = "rot0"
    private var jpegActiveWidth = 0
    private var jpegActiveHeight = 0
    private var jpeg: Data?
    private var frameAt: Double?
    private var encodedFrames = 0
    private var lastTick: Double?
    private var lastEncodeMs = 0.0
    private var maxEncodeMs = 0.0
    private var maxTickGapMs = 0.0
    private var slowFrames: [[String: Double]] = []
    private var error: String?
    private var listenFailure: NWError?
    private var closed = false
    private var gestures = NativePreviewGestures()
    private(set) var url = ""

    init(port: UInt16 = UInt16(PreviewConfiguration.defaultPort), device: NativePreviewDevice = .unknown, connectionStatus: @escaping () -> [String: Any]? = { nil }, encodeFrame: @escaping (NativeVideoSnapshot.Frame, NativeDisplay, CIContext) throws -> EncodedJPEG = { try NativePreview.encodeJPEG($0, display: $1, context: $2) }) throws {
        self.device = device; self.bezel = NativePreviewBezel.load(device: device)
        self.connectionStatus = connectionStatus
        self.encodeFrame = encodeFrame
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        do { listener = try NWListener(using: parameters) }
        catch { throw Self.listenerError(error, port: port) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = self.listener.port { self.url = "http://127.0.0.1:\(port)/\(self.token)/" }
                ready.signal()
            case .failed(let failure), .waiting(let failure):
                self.listenFailure = failure; self.error = String(describing: failure); ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success,
              queue.sync(execute: { !url.isEmpty && error == nil }) else {
            listener.cancel()
            if let failure = queue.sync(execute: { listenFailure }) { throw Self.listenerError(failure, port: port) }
            throw IPhoneUseError("preview_listen_failed", "Timed out opening the preview listener at 127.0.0.1:\(port)")
        }
        queue.sync {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30)
            timer.setEventHandler { [weak self] in self?.encodeLatest(); self?.flushWaiting() }
            timer.resume(); self.timer = timer
        }
    }

    private static func listenerError(_ error: Error, port: UInt16) -> IPhoneUseError {
        if let failure = error as? NWError, case .posix(.EADDRINUSE) = failure {
            return IPhoneUseError("preview_port_in_use", "Preview port \(port) is occupied on 127.0.0.1. No other process was stopped. Retry in this session with preview --port PORT --no-open using another port (1024...65535); config set preview-port PORT saves a future default.")
        }
        return IPhoneUseError("preview_listen_failed", "Cannot open preview at 127.0.0.1:\(port): \(error). Retry with preview --port PORT --no-open using another port.")
    }

    func status(for options: NativePreviewOptions) throws -> [String: Any] {
        let result = status()
        if options.explicitPort, result["port"] as? Int != Int(options.port) {
            throw IPhoneUseError("preview_already_running", "Preview is already running at \(url). Use its URL, or run preview --stop before starting preview --port \(options.port) --no-open. The existing preview was not changed.")
        }
        return result
    }

    func attach(_ receiver: NativeRTPReceiver, display: NativeDisplay, device: NativePreviewDevice? = nil) {
        queue.sync {
            guard !closed else { return }
            if let device, device.productType != self.device.productType || device.name != self.device.name {
                self.device = device; bezel = NativePreviewBezel.load(device: device)
            }
            if self.receiver !== receiver || self.display != display {
                gestures.clear()
                jpeg = nil; frameAt = nil; lastSubmittedFrameAt = nil; bindingGeneration += 1
            }
            self.receiver = receiver; self.display = display; error = nil
        }
    }

    func suspend(_ reason: String) {
        queue.sync { gestures.clear(); bindingGeneration += 1; receiver = nil; display = nil; jpeg = nil; frameAt = nil; lastSubmittedFrameAt = nil; error = reason }
    }

    var gestureRotation: String? { queue.sync { display?.rotation } }

    func showGesture(_ gesture: NativePreviewGesture) {
        queue.async { [weak self] in
            guard let self, !self.closed, let display = self.display,
                  display.rotation == gesture.rotation else { return }
            self.gestures.append(gesture, now: ProcessInfo.processInfo.systemUptime)
            self.flushWaitingGestures()
        }
    }

    func status() -> [String: Any] { queue.sync { facts() } }

    private func facts() -> [String: Any] {
        let health = receiver?.health() ?? [:]
        let healthy = health["healthy"] as? Bool == true
        return ["state": closed ? "stopped" : (error != nil ? "unavailable" : (healthy && jpeg != nil ? "streaming" : "waiting")),
                "device": device.facts, "bezel": bezel?.profile.facts as Any? ?? NSNull(),
                "connection": connectionStatus() as Any? ?? NSNull(),
                "url": url, "port": listener.port.map { Int($0.rawValue) } as Any? ?? NSNull(),
                "readOnly": true, "source": "owned_native_rtp", "maxFPS": 30,
                "encodedFrames": encodedFrames, "encodingInFlight": contexts.count < 2, "inFlightEncodes": 2 - contexts.count, "discardedEncodes": discardedEncodes, "frameAgeSeconds": frameAt.map { ProcessInfo.processInfo.systemUptime - $0 } as Any? ?? NSNull(),
                "timing": ["lastEncodeMs": lastEncodeMs, "maxEncodeMs": maxEncodeMs,
                           "encoding": "core_image_jpeg", "stageTiming": "combined",
                           "maxConversionMs": NSNull(), "maxCompressionMs": NSNull(),
                           "maxTickGapMs": maxTickGapMs, "slowFrames": slowFrames],
                "mediaHealthy": healthy, "rotation": display?.rotation as Any? ?? NSNull(),
                "error": error as Any? ?? NSNull(), "media": health]
    }

    private func encodeLatest() {
        let started = ProcessInfo.processInfo.systemUptime
        let tickGap = lastTick.map { (started - $0) * 1000 } ?? 0
        lastTick = started; maxTickGapMs = max(maxTickGapMs, tickGap)
        guard !closed, !contexts.isEmpty, let receiver, let display, receiver.health()["healthy"] as? Bool == true else { return }
        guard let frame = receiver.snapshots?.previewFrame(includeReducedResolution: true) else {
            if let failure = receiver.snapshots?.status()["lastError"] as? String { error = failure; jpeg = nil }
            return
        }
        guard frame.completedAt != lastSubmittedFrameAt else { return }
        let admittedAt = ProcessInfo.processInfo.systemUptime
        let sourceReadMs = (admittedAt - started) * 1000
        let generation = bindingGeneration
        let context = contexts.removeLast()
        lastSubmittedFrameAt = frame.completedAt
        // Two bounded slots let a fresh frame bypass one slow conversion.
        // Timer ticks while both are busy are skipped, never queued.
        encoderQueue.async { [self] in
            let encodingStarted = ProcessInfo.processInfo.systemUptime
            let result = Result { try autoreleasepool { try encodeFrame(frame, display, context) } }
            let encodeMs = (ProcessInfo.processInfo.systemUptime - encodingStarted) * 1000
            let workerWaitMs = (encodingStarted - admittedAt) * 1000
            queue.async { [self] in
                contexts.append(context)
                guard !closed, bindingGeneration == generation else { return }
                maxEncodeMs = max(maxEncodeMs, encodeMs)
                if tickGap > 100 || encodeMs > 100 || sourceReadMs > 100 || workerWaitMs > 100 {
                    slowFrames.append(["wallTime": Date().timeIntervalSince1970, "tickGapMs": tickGap,
                                       "encodeMs": encodeMs, "sourceReadMs": sourceReadMs, "workerWaitMs": workerWaitMs,
                                       "sourceAgeMs": (encodingStarted - frame.completedAt) * 1000])
                    if slowFrames.count > 120 { slowFrames.removeFirst() }
                }
                if let frameAt, frame.completedAt <= frameAt { discardedEncodes += 1; return }
                switch result {
                case .success(let encoded):
                    jpegActiveWidth = frame.image.activeWidth; jpegActiveHeight = frame.image.activeHeight
                    jpeg = encoded.data; jpegRotation = display.rotation; frameAt = frame.completedAt; lastEncodeMs = encodeMs; encodedFrames += 1; error = nil
                case .failure(let failure):
                    error = String(describing: failure); jpeg = nil
                    if lastSubmittedFrameAt == frame.completedAt { lastSubmittedFrameAt = nil }
                }
                // Publish before another encode; HTTP and health never wait
                // behind image conversion or a file decoder's GPU workload.
                flushWaiting()
            }
        }
    }

    static func encode(_ frame: NativeVideoSnapshot.Frame, display: NativeDisplay, context: CIContext = CIContext()) throws -> Data {
        try encodeJPEG(frame, display: display, context: context).data
    }

    private static func encodeJPEG(_ frame: NativeVideoSnapshot.Frame, display: NativeDisplay, context: CIContext) throws -> EncodedJPEG {
        _ = try NativeSnapshotImage.validateGeometry(frame, display: display, allowReducedResolution: true)
        let pixels = frame.pixels
        // VRA scales the entire encoded canvas, including its right/bottom
        // padding, into the top-left active rectangle. Crop the proportional
        // native rectangle before restoring its axes; stretching the entire
        // active rectangle would include padding and shift screen landmarks.
        let scaleX = Double(CVPixelBufferGetWidth(pixels)) / Double(frame.image.activeWidth)
        let scaleY = Double(CVPixelBufferGetHeight(pixels)) / Double(frame.image.activeHeight)
        let nativeWidth = Double(frame.image.nativeWidth) / scaleX
        let nativeHeight = Double(frame.image.nativeHeight) / scaleY
        // CI coordinates start at the bottom, pixel-buffer rows at the top.
        var image = CIImage(cvPixelBuffer: pixels).cropped(to: CGRect(x: 0,
            y: Double(CVPixelBufferGetHeight(pixels)) - nativeHeight,
            width: nativeWidth, height: nativeHeight))
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        if display.rotation == "rot90" { image = image.oriented(.right) }
        if display.rotation == "rot270" { image = image.oriented(.left) }
        let scale = min(1, 960 / max(image.extent.width, image.extent.height))
        let output = CGRect(x: 0, y: 0, width: min(960, ceil(image.extent.width * scale)),
                            height: min(960, ceil(image.extent.height * scale)))
        // The short edge is often fractional (1170 × 960 / 2532 = 443.60).
        // Extend the validated native edge, not the decoder padding, before
        // resampling. Otherwise the last JPEG column composites partial alpha
        // against white, leaving a visible gray seam even on a black screen.
        image = image.clampedToExtent().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: output)
        // Let Core Image render directly for JPEG export instead of materializing
        // an RGBA CGImage and handing it to a separate ImageIO destination. Keep
        // color management, the native crop, output dimensions and quality intact.
        // Rendering and compression are fused: report their combined wall time,
        // never zero-valued timings pretending to measure the individual stages.
        guard let data = context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]) else {
            throw IPhoneUseError("preview_encoding_failed", "JPEG encoding failed")
        }
        return EncodedJPEG(data: data)
    }

    private func accept(_ connection: NWConnection) {
        guard !closed, connections.count < 8 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections.removeValue(forKey: id); self?.waiting.removeValue(forKey: id); self?.waitingGestures.removeValue(forKey: id)
            default: break
            }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
        queue.asyncAfter(deadline: .now() + 3) { [weak connection] in connection?.cancel() }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, failure in
            guard let self, !self.closed else { connection.cancel(); return }
            var buffer = buffer; buffer.append(data ?? Data())
            guard buffer.count <= 8192, failure == nil else { connection.cancel(); return }
            guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                if complete { connection.cancel() } else { self.receive(connection, buffer: buffer) }
                return
            }
            let lines = request.components(separatedBy: "\r\n")
            let parts = (lines.first ?? "").split(separator: " ")
            let host = URL(string: self.url)!.host! + ":" + String(self.listener.port!.rawValue)
            guard parts.count == 3, parts[0] == "GET",
                  lines.contains(where: { $0.lowercased() == "host: \(host)" }),
                  !lines.contains(where: { $0.lowercased().hasPrefix("origin:") && $0 != "Origin: http://\(host)" }) else {
                self.send(connection, code: "403 Forbidden", type: "text/plain", data: Data()); return
            }
            let path = String(parts[1]).components(separatedBy: "?")[0]
            switch path {
            case "/\(self.token)/": self.send(connection, type: "text/html; charset=utf-8", data: Data(NativePreviewPage.html.utf8))
            case "/\(self.token)/favicon.png":
                self.send(connection, type: "image/png", data: NativePreviewPage.faviconPNG, cache: "private, max-age=86400")
            case "/\(self.token)/bezel":
                if let data = self.bezel?.png {
                    self.send(connection, type: "image/png", data: data, cache: "private, max-age=86400")
                } else { self.send(connection, code: "404 Not Found", type: "text/plain", data: Data()) }
            case "/\(self.token)/state": self.send(connection, type: "application/json", data: (try? jsonData(self.facts())) ?? Data())
            case "/\(self.token)/gestures":
                let query = URLComponents(string: "http://localhost" + String(parts[1]))?.queryItems
                let after = query?.first(where: { $0.name == "after" })?.value.flatMap(Int.init)
                if let after, after == self.gestures.sequence {
                    self.waitingGestures[ObjectIdentifier(connection)] = (after, ProcessInfo.processInfo.systemUptime + 1)
                } else { self.sendGestures(connection, after: after) }
            case "/\(self.token)/frame":
                let query = URLComponents(string: "http://localhost" + String(parts[1]))?.queryItems
                if let after = query?.first(where: { $0.name == "after" })?.value.flatMap(Int.init),
                   after == self.encodedFrames, self.error == nil {
                    self.waiting[ObjectIdentifier(connection)] = (after, ProcessInfo.processInfo.systemUptime + 1)
                } else { self.sendFrame(connection) }
            default: self.send(connection, code: "404 Not Found", type: "text/plain", data: Data())
            }
        }
    }

    private func sendFrame(_ connection: NWConnection) {
        if let jpeg, error == nil, receiver?.health()["healthy"] as? Bool == true {
            send(connection, type: "image/jpeg", data: jpeg,
                 headers: "X-Preview-Rotation: \(jpegRotation)\r\nX-Preview-Active-Width: \(jpegActiveWidth)\r\nX-Preview-Active-Height: \(jpegActiveHeight)\r\nX-Preview-Sequence: \(encodedFrames)\r\nX-Preview-Frame-Age-Ms: \((ProcessInfo.processInfo.systemUptime - (frameAt ?? 0)) * 1000)\r\nX-Preview-Encode-Ms: \(lastEncodeMs)\r\n")
        } else { send(connection, code: "503 Service Unavailable", type: "text/plain", data: Data()) }
    }

    private func flushWaiting() {
        flushWaitingGestures()
        let now = ProcessInfo.processInfo.systemUptime
        for (id, request) in waiting where request.sequence != encodedFrames || request.deadline <= now || error != nil {
            waiting.removeValue(forKey: id)
            if let connection = connections[id] { sendFrame(connection) }
        }
    }

    private func sendGestures(_ connection: NWConnection, after: Int?) {
        send(connection, type: "application/json", data: (try? jsonData(
            gestures.response(after: after, now: ProcessInfo.processInfo.systemUptime))) ?? Data())
    }

    private func flushWaitingGestures() {
        let now = ProcessInfo.processInfo.systemUptime
        for (id, request) in waitingGestures where request.sequence != gestures.sequence || request.deadline <= now {
            waitingGestures.removeValue(forKey: id)
            if let connection = connections[id] { sendGestures(connection, after: request.sequence) }
        }
    }

    private func send(_ connection: NWConnection, code: String = "200 OK", type: String, data: Data, headers: String = "", cache: String = "no-store") {
        var response = Data("HTTP/1.1 \(code)\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\n\(headers)Cache-Control: \(cache)\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; img-src 'self' blob:; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n".utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    func close() {
        queue.sync {
            guard !closed else { return }
            closed = true; bindingGeneration += 1; timer?.cancel(); timer = nil; receiver = nil; jpeg = nil
            listener.cancel(); connections.values.forEach { $0.cancel() }; connections.removeAll(); waiting.removeAll(); waitingGestures.removeAll()
        }
    }

}
