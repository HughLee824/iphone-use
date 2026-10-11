import XCTest
import Network
@testable import IPhoneUseCore

final class JSONTransportTests: XCTestCase {
    private func server(_ handler: @escaping ([String: Any], @escaping JSONServer.Reply) -> Void) throws -> (JSONServer, String) {
        let path = "/private/tmp/iu-json-\(UUID().uuidString.prefix(8)).sock"
        let server = try JSONServer(path: path)
        let ready = expectation(description: "listener ready")
        server.onRequest = handler
        server.start { ready.fulfill() }
        wait(for: [ready], timeout: 3)
        addTeardownBlock { server.stopAccepting(); try? FileManager.default.removeItem(atPath: path) }
        return (server, path)
    }

    func testLargeRepliesArriveIntactWithoutReplayingRequests() throws {
        // Real text diagnostics exceeded 10 KB; immediate server cancellation
        // lost these replies despite the action having executed. Also span
        // multiple 64 KB client receives, retaining the complete nested result.
        let completed = expectation(description: "all connections closed")
        completed.expectedFulfillmentCount = 40
        let lock = NSLock()
        var ids: [String] = []
        let (_, path) = try server { request, reply in
            lock.lock(); ids.append(request["id"] as! String); lock.unlock()
            reply(["id": request["id"]!, "outcome": "unknown",
                   "result": ["payload": String(repeating: "中🙂", count: request["count"] as! Int)],
                   "observation": ["result": ["observation": "o5"]]], { completed.fulfill() })
        }
        var sent: [String] = []
        for count in [1600, 40000] {
            for _ in 0..<20 {
                let id = UUID().uuidString
                sent.append(id)
                let response = try JSONTransport.exchange(endpoint: .unix(path: path),
                    request: ["id": id, "count": count], timeout: 3)
                XCTAssertEqual(response["outcome"] as? String, "unknown")
                XCTAssertEqual((response["result"] as? [String: Any])?["payload"] as? String,
                               String(repeating: "中🙂", count: count))
                XCTAssertEqual(((response["observation"] as? [String: Any])?["result"] as? [String: Any])?["observation"] as? String, "o5")
            }
        }
        wait(for: [completed], timeout: 3)
        lock.lock(); let received = ids; lock.unlock()
        XCTAssertEqual(received, sent)
    }

    func testReplyCompletionIsBoundedWhenPeerDoesNotClose() throws {
        let closed = expectation(description: "stalled peer released once")
        closed.assertForOverFulfill = true
        let (_, path) = try server { request, reply in reply(["id": request["id"]!, "ok": true], { closed.fulfill() }) }
        let peer = NWConnection(to: .unix(path: path), using: .tcp)
        defer { peer.cancel() }
        peer.stateUpdateHandler = { state in
            if case .ready = state {
                peer.send(content: Data("{\"id\":\"stalled\"}\n".utf8), completion: .contentProcessed { _ in })
            }
        }
        peer.start(queue: DispatchQueue(label: "test.stalled-peer"))
        wait(for: [closed], timeout: 7)
    }

    func testLostOrMismatchedReplyRemainsUncertainAndIsNotRetried() throws {
        for mismatch in [false, true] {
            let received = expectation(description: "one request")
            received.assertForOverFulfill = true
            let (_, path) = try server { _, reply in
                received.fulfill()
                if mismatch { reply(["id": "wrong-id", "ok": true], {}) }
                // Otherwise simulate a host that never replies after admission.
            }
            XCTAssertThrowsError(try JSONTransport.exchange(endpoint: .unix(path: path),
                request: ["id": UUID().uuidString], timeout: 0.2)) { error in
                XCTAssertEqual((error as? TransportError)?.possiblySent, true)
            }
            wait(for: [received], timeout: 1)
        }
    }
}
