import Foundation

// Heartbeats carry no media and never renew the device session's idle deadline.
final class PreviewPublication {
    let url: String
    let port: UInt16
    private let client: PreviewServiceClient
    private let fields: [String: Any]
    private let queue = DispatchQueue(label: "iphone-use.preview.lease")
    private let lock = NSLock()
    private var lost: String?
    private var stopped = false
    private var timer: DispatchSourceTimer?
    var failure: String? { lock.lock(); defer { lock.unlock() }; return lost }

    init(client: PreviewServiceClient, device: String, owner: String, sourceURL: String) throws {
        self.client = client; port = client.port
        fields = ["device": device, "owner": owner]
        var attach = fields; attach["url"] = sourceURL
        let response = try client.call("attach", fields: attach)
        guard let url = response["url"] as? String else {
            throw IPhoneUseError("preview_service_failed", "Service did not return a viewer URL")
        }
        self.url = url
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.renew() }
        timer.resume(); self.timer = timer
    }

    private func renew() {
        guard !stopped else { return }
        do { try client.call("renew", fields: fields) } catch {
            lock.lock(); lost = "Preview binding lost; explicitly stop/start preview"; lock.unlock()
            timer?.cancel(); timer = nil
        }
    }

    func close() {
        queue.sync {
            guard !stopped else { return }
            stopped = true; timer?.cancel(); timer = nil
            try? client.call("detach", fields: fields)
        }
    }
}
