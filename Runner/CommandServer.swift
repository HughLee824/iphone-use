import Network
import XCTest
import Darwin

final class CommandServer {
    struct Request {
        let body: [String: Any]
        let connection: NWConnection
    }

    let requests: AsyncStream<Request>
    private let continuation: AsyncStream<Request>.Continuation
    private let listener: NWListener
    private let queue = DispatchQueue(label: "iphone-use.commands")
    private var connections: [NWConnection] = []

    init() throws {
        var sink: AsyncStream<Request>.Continuation!
        requests = AsyncStream { sink = $0 }
        continuation = sink
        let parameters = NWParameters.tcp
        let host = ProcessInfo.processInfo.environment["IPHONE_USE_LISTEN_HOST"] ?? "127.0.0.1"
        guard host == "127.0.0.1" || (IPv6Address(host) != nil && host != "::") else {
            throw CommandError("invalid_listen_address")
        }
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: 47821)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { print("IPHONE_USE_LIVE_READY host=\(host) port=47821") }
            if case .failed(let error) = state {
                print("IPHONE_USE_LISTENER_FAILED \(error)")
                self?.continuation.finish()
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connections.append(connection)
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                if case .cancelled = state { self?.connections.removeAll { $0 === connection } }
            }
            connection.start(queue: queue)
            receive(connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            buffer.append(data ?? Data())
            guard buffer.count <= 65536, error == nil else { connection.cancel(); return }
            if let newline = buffer.firstIndex(of: 10) {
                guard
                    let body = (try? JSONSerialization.jsonObject(with: buffer[..<newline])) as? [String: Any]
                else {
                    connection.cancel()
                    return
                }
                continuation.yield(Request(body: body, connection: connection))
            } else if done {
                connection.cancel()
            } else {
                receive(connection, buffer: buffer)
            }
        }
    }

    // Advisory only: delivery must not gate or replay device input.
    func progress(_ body: [String: Any], to request: Request) {
        guard var data = try? JSONSerialization.data(withJSONObject: body) else { return }
        data.append(10)
        request.connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func reply(_ body: [String: Any], to request: Request) async throws {
        var data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        data.append(10)
        await withCheckedContinuation { (sent: CheckedContinuation<Void, Never>) in
            request.connection.send(
                content: data,
                completion: .contentProcessed { _ in
                    request.connection.cancel()
                    sent.resume()
                })
        }
    }

    func stop() {
        listener.cancel()
        continuation.finish()
        queue.async { [self] in connections.forEach { $0.cancel() } }
    }
}
