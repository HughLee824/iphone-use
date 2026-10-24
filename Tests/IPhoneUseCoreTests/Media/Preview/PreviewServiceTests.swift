import XCTest
@testable import IPhoneUseCore

final class PreviewServiceTests: XCTestCase {
    private func service() throws -> PreviewService {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pv-" + UUID().uuidString.prefix(8))
        let service = try PreviewService(directory: root, port: 0)
        try service.start()
        addTeardownBlock { service.stop(); try? FileManager.default.removeItem(at: root) }
        return service
    }

    private func get(_ url: String, method: String = "GET", origin: String? = nil) throws -> (Int, Data) {
        var request = URLRequest(url: try XCTUnwrap(URL(string: url)))
        request.httpMethod = method; request.setValue(origin, forHTTPHeaderField: "Origin")
        let done = expectation(description: "HTTP response")
        var result: (Int, Data)?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()); done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return try XCTUnwrap(result)
    }

    func testHTTPIsReadOnlyAndRequiresTokenAndLocalOrigin() throws {
        let service = try service()
        let entry = try service.queue.sync { try service.registry.entry(device: "phone") }
        let base = "http://127.0.0.1:\(service.port)/", url = base + "v/\(entry.token)/"
        XCTAssertEqual(try get(base).0, 404)
        XCTAssertEqual(try get(url).0, 200)
        XCTAssertEqual(try get(url, method: "POST").0, 403)
        XCTAssertEqual(try get(url, origin: "https://example.com").0, 403)
        XCTAssertEqual(try get(url + "attach").0, 404)
        XCTAssertEqual(try get(url + "frame").0, 503)
        let state = try jsonObject(get(url + "state").1)
        XCTAssertEqual(state["state"] as? String, "disconnected")
        XCTAssertEqual(state["readOnly"] as? Bool, true)
        try service.queue.sync { try service.registry.revoke(device: "phone") }
        XCTAssertEqual(try get(url).0, 404)
        XCTAssertEqual(try get(url + "state").0, 404)
    }

    func testSameURLReconnectsOnlyItsDeviceAndRevokeBlocksActiveSource() throws {
        let service = try service(), source = try NativePreview(port: 0)
        defer { source.close() }
        let owner = UUID().uuidString
        let entry = try service.queue.sync {
            try service.registry.attach(device: "phone", owner: owner, url: source.url,
                                        now: ProcessInfo.processInfo.systemUptime)
        }
        let url = "http://127.0.0.1:\(service.port)/v/\(entry.token)/"
        XCTAssertEqual(try jsonObject(get(url + "state").1)["url"] as? String, url)
        service.queue.sync { service.registry.detach(device: "phone", owner: owner) }
        let other = try service.queue.sync {
            try service.registry.attach(device: "other", owner: UUID().uuidString, url: source.url,
                                        now: ProcessInfo.processInfo.systemUptime)
        }
        XCTAssertNotEqual(other.token, entry.token)
        XCTAssertEqual(try jsonObject(get(url + "state").1)["state"] as? String, "disconnected")
        let reconnected = try service.queue.sync {
            try service.registry.attach(device: "phone", owner: UUID().uuidString, url: source.url,
                                        now: ProcessInfo.processInfo.systemUptime)
        }
        XCTAssertEqual(reconnected.token, entry.token)
        XCTAssertEqual(try jsonObject(get(url + "state").1)["url"] as? String, url)
        try service.queue.sync { try service.registry.revoke(device: "phone") }
        XCTAssertEqual(try get(url + "state").0, 404)
    }

    func testIPCRequiresPrivateCredential() throws {
        let service = try service()
        let response = service.queue.sync { service.control(["id": "test", "version": 1, "op": "ping"]) }
        XCTAssertEqual(response["ok"] as? Bool, false)
        let client = try PreviewServiceClient(port: service.port, directory: service.directory)
        XCTAssertEqual(try client.call("ping")["ok"] as? Bool, true)
    }
    func testDelayedSourceResponseIsRejectedAfterReplacementOrRevocation() throws {
        for revoke in [false, true] {
            let service = try service(), source = try NativePreview(port: 0)
            defer { source.close() }
            let owner = UUID().uuidString
            let entry = try service.queue.sync {
                try service.registry.attach(device: "phone", owner: owner, url: source.url,
                                            now: ProcessInfo.processInfo.systemUptime)
            }
            let url = "http://127.0.0.1:\(service.port)/v/\(entry.token)/gestures?after=0"
            let done = expectation(description: "late response")
            var status = 0
            URLSession.shared.dataTask(with: try XCTUnwrap(URL(string: url))) { _, response, _ in
                status = (response as? HTTPURLResponse)?.statusCode ?? 0; done.fulfill()
            }.resume()
            let deadline = ProcessInfo.processInfo.systemUptime + 0.8
            while source.queue.sync(execute: { source.waitingGestures.isEmpty }),
                ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertFalse(source.queue.sync { source.waitingGestures.isEmpty })
            try service.queue.sync {
                if revoke { try service.registry.revoke(device: "phone") } else {
                    service.registry.detach(device: "phone", owner: owner)
                    _ = try service.registry.attach(device: "phone", owner: UUID().uuidString, url: source.url,
                                                    now: ProcessInfo.processInfo.systemUptime)
                }
            }
            wait(for: [done], timeout: 4)
            XCTAssertEqual(status, revoke ? 404 : 409)
        }
    }

    func testPublicationReportsRevocationAndNeverReregistersItself() throws {
        let service = try service(), source = try NativePreview(port: 0)
        defer { source.close() }
        let client = try PreviewServiceClient(port: service.port, directory: service.directory)
        let publication = try PreviewPublication(client: client, device: "phone", owner: UUID().uuidString,
                                                 sourceURL: source.url)
        defer { publication.close() }
        XCTAssertEqual(try get(publication.url).0, 200)
        try client.call("revoke", fields: ["device": "phone"])
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while publication.failure == nil, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertNotNil(publication.failure)
        XCTAssertEqual(try get(publication.url).0, 404)
        XCTAssertNil(service.queue.sync {
            service.registry.source(device: "phone", now: ProcessInfo.processInfo.systemUptime)
        })
    }

}
