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
    let queue = DispatchQueue(label: "iphone-use.preview", qos: .userInitiated)
    let encoderQueue = DispatchQueue(
        label: "iphone-use.preview.encode", qos: .userInitiated, attributes: .concurrent)
    let encodeFrame: (NativeVideoSnapshot.Frame, NativeDisplay, CIContext) throws -> EncodedJPEG
    private let connectionStatus: () -> [String: Any]?
    var lastSubmittedFrameAt: Double?
    var discardedEncodes = 0
    var bindingGeneration = 0
    let listener: NWListener
    let token = UUID().uuidString
    // This is a small JPEG, not a full-size video encode. CPU rendering avoids
    // queueing its resize/color conversion behind live video and file decoding.
    var contexts = (0..<2).map { _ in
        CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: true])
    }
    private var timer: DispatchSourceTimer?
    var waiting: [ObjectIdentifier: (sequence: Int, deadline: Double)] = [:]
    var waitingGestures: [ObjectIdentifier: (sequence: Int, deadline: Double)] = [:]
    var connections: [ObjectIdentifier: NWConnection] = [:]
    var receiver: NativeRTPReceiver?
    var display: NativeDisplay?
    private var device: NativePreviewDevice
    var bezel: NativePreviewBezel?
    var jpegRotation = "rot0"
    var jpegActiveWidth = 0
    var jpegActiveHeight = 0
    var jpeg: Data?
    var firstFrameDeadline: Double?
    var frameAt: Double?
    var encodedFrames = 0
    var lastTick: Double?
    var lastEncodeMs = 0.0
    var maxEncodeMs = 0.0
    var maxTickGapMs = 0.0
    var slowFrames: [[String: Double]] = []
    var error: String?
    private var listenFailure: NWError?
    var closed = false
    var gestures = NativePreviewGestures()
    private(set) var url = ""

    init(
        port: UInt16 = UInt16(PreviewConfiguration.defaultPort), device: NativePreviewDevice = .unknown,
        connectionStatus: @escaping () -> [String: Any]? = { nil },
        encodeFrame: @escaping (NativeVideoSnapshot.Frame, NativeDisplay, CIContext) throws -> EncodedJPEG = {
            try NativePreview.encodeJPEG($0, display: $1, context: $2)
        }
    ) throws {
        self.device = device; self.bezel = NativePreviewBezel.load(device: device)
        self.connectionStatus = connectionStatus
        self.encodeFrame = encodeFrame
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        do { listener = try NWListener(using: parameters) } catch {
            throw Self.listenerError(error, port: port)
        }
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
            queue.sync(execute: { !url.isEmpty && error == nil })
        else {
            listener.cancel()
            if let failure = queue.sync(execute: { listenFailure }) {
                throw Self.listenerError(failure, port: port)
            }
            throw IPhoneUseError(
                "preview_listen_failed", "Timed out opening the preview listener at 127.0.0.1:\(port)")
        }
        queue.sync {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30)
            timer.setEventHandler { [weak self] in
                self?.encodeLatest(); self?.flushWaiting()
            }
            timer.resume(); self.timer = timer
        }
    }

    private static func listenerError(_ error: Error, port: UInt16) -> IPhoneUseError {
        if let failure = error as? NWError, case .posix(.EADDRINUSE) = failure {
            return IPhoneUseError(
                "preview_port_in_use",
                """
                Preview port \(port) is occupied on 127.0.0.1. No other process was stopped. Retry in this\
                 session with preview --port PORT --no-open using another port (1024...65535); config set\
                 preview-port PORT saves a future default.
                """
            )
        }
        return IPhoneUseError(
            "preview_listen_failed",
            """
            Cannot open preview at 127.0.0.1:\(port): \(error). Retry with preview --port PORT --no-open using\
             another port.
            """
        )
    }

    func status(for options: NativePreviewOptions) throws -> [String: Any] {
        let result = status()
        if options.explicitPort, result["port"] as? Int != Int(options.port) {
            throw IPhoneUseError(
                "preview_already_running",
                """
                Preview is already running at \(url). Use its URL, or run preview --stop before starting\
                 preview --port \(options.port) --no-open. The existing preview was not changed.
                """
            )
        }
        return result
    }

    func attach(_ receiver: NativeRTPReceiver, display: NativeDisplay, device: NativePreviewDevice? = nil) {
        queue.sync {
            guard !closed else { return }
            if let device, device.productType != self.device.productType || device.name != self.device.name {
                self.device = device; bezel = NativePreviewBezel.load(device: device)
            }
            if self.receiver !== receiver || self.display?.geometry != display.geometry {
                gestures.clear()
                jpeg = nil; frameAt = nil; lastSubmittedFrameAt = nil; bindingGeneration += 1
                firstFrameDeadline = ProcessInfo.processInfo.systemUptime + 3; error = nil
            }
            self.receiver = receiver; self.display = display
        }
    }

    func suspend(_ reason: String) {
        queue.sync {
            gestures.clear(); bindingGeneration += 1; receiver = nil; display = nil; jpeg = nil; frameAt = nil
            firstFrameDeadline = nil; lastSubmittedFrameAt = nil; error = reason
        }
    }

    var gestureRotation: String? { queue.sync { display?.rotation } }

    func showGesture(_ gesture: NativePreviewGesture) {
        queue.async { [weak self] in
            guard let self, !self.closed, let display = self.display,
                display.rotation == gesture.rotation
            else { return }
            self.gestures.append(gesture, now: ProcessInfo.processInfo.systemUptime)
            self.flushWaitingGestures()
        }
    }

    func status() -> [String: Any] { queue.sync { facts() } }

    func facts() -> [String: Any] {
        let health = receiver?.health() ?? [:]
        let healthy = health["healthy"] as? Bool == true
        return [
            "state": closed
                ? "stopped"
                : (error != nil ? "unavailable" : (healthy && jpeg != nil ? "streaming" : "waiting")),
            "device": device.facts, "bezel": bezel?.profile.facts as Any? ?? NSNull(),
            "connection": connectionStatus() as Any? ?? NSNull(),
            "url": url, "port": listener.port.map { Int($0.rawValue) } as Any? ?? NSNull(),
            "readOnly": true, "source": "owned_native_rtp", "maxFPS": 30,
            "encodedFrames": encodedFrames, "encodingInFlight": contexts.count < 2,
            "inFlightEncodes": 2 - contexts.count, "discardedEncodes": discardedEncodes,
            "frameAgeSeconds": frameAt.map { ProcessInfo.processInfo.systemUptime - $0 } as Any? ?? NSNull(),
            "timing": [
                "lastEncodeMs": lastEncodeMs, "maxEncodeMs": maxEncodeMs,
                "encoding": "core_image_jpeg", "stageTiming": "combined",
                "maxConversionMs": NSNull(), "maxCompressionMs": NSNull(),
                "maxTickGapMs": maxTickGapMs, "slowFrames": slowFrames
            ],
            "mediaHealthy": healthy, "rotation": display?.rotation as Any? ?? NSNull(),
            "error": error as Any? ?? NSNull(), "media": health
        ]
    }

    func close() {
        queue.sync {
            guard !closed else { return }
            closed = true; bindingGeneration += 1; timer?.cancel(); timer = nil; receiver = nil; jpeg = nil
            listener.cancel(); connections.values.forEach { $0.cancel() }; connections.removeAll()
            waiting.removeAll()
            waitingGestures.removeAll()
        }
    }

}
