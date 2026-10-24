import Foundation
import Network
import CoreImage
import ImageIO

extension NativePreview {

    func accept(_ connection: NWConnection) {
        guard !closed, connections.count < 8 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections.removeValue(forKey: id); self?.waiting.removeValue(forKey: id)
                self?.waitingGestures.removeValue(forKey: id)
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
            self.respond(to: request, on: connection)
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let host = URL(string: self.url)!.host! + ":" + String(self.listener.port!.rawValue)
        guard parts.count == 3, parts[0] == "GET",
            lines.contains(where: { $0.lowercased() == "host: \(host)" }),
            !lines.contains(where: { $0.lowercased().hasPrefix("origin:") && $0 != "Origin: http://\(host)" })
        else {
            self.send(connection, code: "403 Forbidden", type: "text/plain", data: Data()); return
        }
        let path = String(parts[1]).components(separatedBy: "?")[0]
        if !matchesGeneration(String(parts[1])) {
            send(connection, code: "409 Conflict", type: "text/plain", data: Data()); return
        }
        route(path: path, target: String(parts[1]), on: connection)
    }

    private func route(path: String, target: String, on connection: NWConnection) {
        switch path {
        case "/\(self.token)/":
            self.send(connection, type: "text/html; charset=utf-8", data: Data(NativePreviewPage.html.utf8))
        case "/\(self.token)/favicon.png":
            self.send(
                connection, type: "image/png", data: NativePreviewPage.faviconPNG,
                cache: "private, max-age=86400")
        case "/\(self.token)/bezel":
            if let data = self.bezel?.png {
                self.send(connection, type: "image/png", data: data, cache: "private, max-age=86400")
            } else {
                self.send(connection, code: "404 Not Found", type: "text/plain", data: Data())
            }
        case "/\(self.token)/state":
            self.send(connection, type: "application/json", data: (try? jsonData(self.facts())) ?? Data())
        case "/\(self.token)/gestures":
            let query = URLComponents(string: "http://localhost" + target)?.queryItems
            let after = query?.first(where: { $0.name == "after" })?.value.flatMap(Int.init)
            if let after, after == self.gestures.sequence {
                self.waitingGestures[ObjectIdentifier(connection)] = (
                    after, ProcessInfo.processInfo.systemUptime + 1
                )
            } else {
                self.sendGestures(connection, after: after)
            }
        case "/\(self.token)/frame":
            respondWithFrame(to: target, on: connection)
        default: self.send(connection, code: "404 Not Found", type: "text/plain", data: Data())
        }
    }

    private func matchesGeneration(_ target: String) -> Bool {
        let query = URLComponents(string: "http://localhost" + target)?.queryItems
        return query?.first(where: { $0.name == "generation" })?.value.map { $0 == generation } ?? true
    }

    private func sendFrame(_ connection: NWConnection) {
        if let jpeg, error == nil, receiver?.health()["healthy"] as? Bool == true {
            send(
                connection, type: "image/jpeg", data: jpeg,
                headers:
                    """
                    X-Preview-Rotation: \(jpegRotation)\r\nX-Preview-Active-Width:\
                     \(jpegActiveWidth)\r\nX-Preview-Active-Height: \(jpegActiveHeight)\r\nX-Preview-Sequence:\
                     \(encodedFrames)\r\nX-Preview-Frame-Age-Ms:\
                     \((ProcessInfo.processInfo.systemUptime - (frameAt ?? 0)) * 1000)\r\nX-Preview-Encode-Ms:\
                     \(lastEncodeMs)\r\n
                    """
            )
        } else {
            send(connection, code: "503 Service Unavailable", type: "text/plain", data: Data())
        }
    }

    func flushWaiting() {
        flushWaitingGestures()
        let now = ProcessInfo.processInfo.systemUptime
        for (id, request) in waiting
        where request.sequence != encodedFrames || request.deadline <= now || error != nil {
            waiting.removeValue(forKey: id)
            if let connection = connections[id] { sendFrame(connection) }
        }
    }

    private func sendGestures(_ connection: NWConnection, after: Int?) {
        send(
            connection, type: "application/json",
            data: (try? jsonData(
                gestures.response(after: after, now: ProcessInfo.processInfo.systemUptime))) ?? Data())
    }

    func flushWaitingGestures() {
        let now = ProcessInfo.processInfo.systemUptime
        for (id, request) in waitingGestures
        where request.sequence != gestures.sequence || request.deadline <= now {
            waitingGestures.removeValue(forKey: id)
            if let connection = connections[id] { sendGestures(connection, after: request.sequence) }
        }
    }

    private func send(
        _ connection: NWConnection, code: String = "200 OK", type: String, data: Data, headers: String = "",
        cache: String = "no-store"
    ) {
        var response = Data(
            """
            HTTP/1.1 \(code)\r\nContent-Type: \(type)\r\nContent-Length:\
             \(data.count)\r\nX-Preview-Generation: \(generation)\r\n\
            \(headers)Cache-Control: \(cache)\r\nReferrer-Policy:\
             no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none';\
             img-src 'self' blob:; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self';\
             frame-ancestors 'none'\r\nConnection: close\r\n\r\n
            """
            .utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
    private func respondWithFrame(to target: String, on connection: NWConnection) {
        let query = URLComponents(string: "http://localhost" + target)?.queryItems
        if let after = query?.first(where: { $0.name == "after" })?.value.flatMap(Int.init),
            after == self.encodedFrames, self.error == nil {
            self.waiting[ObjectIdentifier(connection)] = (after, ProcessInfo.processInfo.systemUptime + 1)
        } else {
            self.sendFrame(connection)
        }
    }

}
