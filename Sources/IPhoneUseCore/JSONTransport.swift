import Foundation
import Network

struct TransportError: Error, CustomStringConvertible {
    let description: String
    let possiblySent: Bool
}

// One bounded JSON line per connection. Never retry a transmitted request.
enum JSONTransport {
    static let limit = 16 * 1024 * 1024

    static func exchange(endpoint: NWEndpoint, request: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        var wire = try jsonData(request)
        wire.append(10)
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "iphone-use.exchange")
        let done = DispatchSemaphore(value: 0)
        var outcome: Result<Data, Error>?
        var buffer = Data()
        var possiblySent = false
        let timer = DispatchSource.makeTimerSource(queue: queue)

        func finish(_ result: Result<Data, Error>) {
            guard outcome == nil else { return }
            outcome = result
            timer.cancel()
            connection.stateUpdateHandler = nil
            connection.cancel()
            done.signal()
        }
        func fail(_ message: String) {
            finish(.failure(TransportError(description: message, possiblySent: possiblySent)))
        }
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                guard outcome == nil else { return }
                buffer.append(data ?? Data())
                if buffer.count > limit { fail("Response exceeds size limit") }
                else if let end = buffer.firstIndex(of: 10) { finish(.success(Data(buffer[..<end]))) }
                else if let error { fail(String(describing: error)) }
                else if complete { fail("Connection closed before response") }
                else { receive() }
            }
        }
        connection.stateUpdateHandler = { state in
            guard outcome == nil else { return }
            switch state {
            case .ready:
                guard !possiblySent else { return }
                possiblySent = true
                connection.send(content: wire, completion: .contentProcessed { error in
                    if let error { fail(String(describing: error)) } else { receive() }
                })
            case .failed(let error), .waiting(let error): fail(String(describing: error))
            case .cancelled: fail("Connection cancelled")
            default: break
            }
        }
        timer.setEventHandler { fail("Response timeout; no automatic replay") }
        timer.schedule(deadline: .now() + timeout)
        timer.resume()
        connection.start(queue: queue)
        done.wait()
        let data = try outcome!.get()
        do {
            let response = try jsonObject(data)
            guard response["id"] as? String == request["id"] as? String else {
                throw IPhoneUseError("mismatched_response", "Response request ID does not match")
            }
            return response
        } catch {
            throw TransportError(description: String(describing: error), possiblySent: true)
        }
    }
}

final class JSONServer {
    typealias Reply = ([String: Any], @escaping () -> Void) -> Void
    private let listener: NWListener
    private let queue = DispatchQueue(label: "iphone-use.ipc")
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    var onRequest: (([String: Any], @escaping Reply) -> Void)?
    var onFailure: ((Error) -> Void)?

    init(path: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        listener = try NWListener(using: parameters)
    }

    func start(ready: @escaping () -> Void) {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { ready() }
            if case .failed(let error) = state { self?.onFailure?(error) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connections[ObjectIdentifier(connection)] = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                if case .cancelled = state, let connection {
                    self?.connections.removeValue(forKey: ObjectIdentifier(connection))
                }
            }
            connection.start(queue: queue)
            receive(connection, buffer: Data())
            queue.asyncAfter(deadline: .now() + 90) { [weak connection] in connection?.cancel() }
        }
        listener.start(queue: queue)
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            buffer.append(data ?? Data())
            guard buffer.count <= 65536, error == nil else { connection.cancel(); return }
            if let end = buffer.firstIndex(of: 10) {
                guard let request = try? jsonObject(Data(buffer[..<end])) else { connection.cancel(); return }
                onRequest?(request) { response, sent in
                    self.queue.async {
                        guard var wire = try? jsonData(response) else { connection.cancel(); sent(); return }
                        wire.append(10)
                        self.sendResponse(wire, on: connection, completion: sent)
                    }
                }
            } else if complete { connection.cancel() }
            else { receive(connection, buffer: buffer) }
        }
    }

    private func sendResponse(_ wire: Data, on connection: NWConnection, completion: @escaping () -> Void) {
        // contentProcessed only acknowledges local processing, not peer receipt.
        // Cancelling here can discard queued Unix-socket bytes (ENETDOWN at the
        // client). Half-close the response, then wait for our one-shot client to
        // consume its JSON line and close. Bound peers that never close.
        let deadline = DispatchSource.makeTimerSource(queue: queue)
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            deadline.cancel()
            connection.cancel()
            completion()
        }
        func awaitPeerClose() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, complete, error in
                guard !finished else { return }
                if complete || error != nil { finish() }
                else { awaitPeerClose() } // Never dispatch another request on this connection.
            }
        }
        deadline.setEventHandler { finish() }
        deadline.schedule(deadline: .now() + 5)
        deadline.resume()
        connection.send(content: wire, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { error in
            guard !finished else { return }
            if error != nil { finish() } else { awaitPeerClose() }
        })
    }

    func stopAccepting() { listener.cancel() }
}
