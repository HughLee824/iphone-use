import Foundation
import Network

extension PreviewService {
    func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.connections.removeValue(forKey: id) }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
        queue.asyncAfter(deadline: .now() + 4) { [weak connection] in connection?.cancel() }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer; buffer.append(data ?? Data())
            guard buffer.count <= 8192, error == nil else { connection.cancel(); return }
            guard let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") else {
                if complete { connection.cancel() } else { self.receive(connection, buffer: buffer) }
                return
            }
            self.respond(request, on: connection)
        }
    }

    private func respond(_ request: String, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n"), host = "127.0.0.1:\(port)"
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count == 3, parts[0] == "GET",
            lines.filter({ $0.lowercased().hasPrefix("host:") }).map({ $0.lowercased() }) == ["host: \(host)"],
            !lines.contains(where: { $0.lowercased().hasPrefix("origin:") && $0 != "Origin: http://\(host)" })
        else { send(connection, code: 403); return }
        let target = String(parts[1]), path = target.components(separatedBy: "?")[0]
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 4, components[0].isEmpty, components[1] == "v",
            let entry = registry.entry(token: String(components[2])) else { send(connection, code: 404); return }
        let resource = String(components[3])
        guard ["", "favicon.png", "state", "frame", "gestures", "bezel"].contains(resource) else {
            send(connection, code: 404); return
        }
        lastActivity = ProcessInfo.processInfo.systemUptime
        if resource.isEmpty {
            send(connection, type: "text/html; charset=utf-8", data: Data(NativePreviewPage.html.utf8)); return
        }
        if resource == "favicon.png" {
            send(connection, type: "image/png", data: NativePreviewPage.faviconPNG); return
        }
        guard let source = registry.source(device: entry.device, now: lastActivity) else {
            if resource == "state" {
                let state: [String: Any] = ["state": "disconnected", "mediaHealthy": false, "readOnly": true,
                                          "generation": registry.idleGeneration(device: entry.device)]
                send(connection, type: "application/json", data: (try? jsonData(state)) ?? Data())
            } else { send(connection, code: 503) }
            return
        }
        forward(target: target, resource: resource, entry: entry, source: source, on: connection)
    }

    private func forward(
        target: String, resource: String, entry: PreviewRegistry.Entry,
        source: PreviewRegistry.Source, on connection: NWConnection
    ) {
        let query = URLComponents(string: "http://localhost" + target)?.percentEncodedQuery
        guard let url = URL(string: source.url + resource + (query.map { "?" + $0 } ?? "")) else {
            send(connection, code: 503); return
        }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 2)
        session.dataTask(with: request) { [weak self, weak connection] data, response, error in
            guard let self, let connection else { return }
            self.queue.async {
                // Re-check authorization and ownership AFTER the asynchronous upstream response.
                guard self.registry.entry(token: entry.token)?.device == entry.device else {
                    self.send(connection, code: 404); return
                }
                guard let current = self.registry.source(
                    device: entry.device, now: ProcessInfo.processInfo.systemUptime),
                    current.owner == source.owner, current.url == source.url else {
                    self.send(connection, code: 409); return
                }
                guard error == nil, let response = response as? HTTPURLResponse, let data,
                    data.count <= 4 * 1024 * 1024 else { self.send(connection, code: 503); return }
                var body = data
                if resource == "state", response.statusCode == 200, var state = try? jsonObject(data) {
                    state["url"] = "http://127.0.0.1:\(self.port)/v/\(entry.token)/"
                    state["port"] = Int(self.port)
                    body = (try? jsonData(state)) ?? Data()
                }
                var headers: [String: String] = [:]
                for (key, value) in response.allHeaderFields {
                    if let key = key as? String, key.lowercased().hasPrefix("x-preview-") {
                        headers[key] = String(describing: value)
                    }
                }
                self.send(connection, code: response.statusCode,
                          type: response.mimeType ?? "application/octet-stream", data: body, headers: headers)
            }
        }.resume()
    }

    private func send(
        _ connection: NWConnection, code: Int = 200, type: String = "text/plain", data: Data = Data(),
        headers: [String: String] = [:]
    ) {
        let extra = headers.map { "\($0): \($1)\r\n" }.joined()
        var response = Data(("HTTP/1.1 \(code) Response\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\n"
                            + extra + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\n"
                            + "X-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; "
                            + "img-src 'self' blob:; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
                            + "connect-src 'self'; frame-ancestors 'none'\r\nConnection: close\r\n\r\n").utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
