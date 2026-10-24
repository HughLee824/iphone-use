import XCTest
@testable import IPhoneUseCore

final class PreviewServiceLifecycleTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pv-" + UUID().uuidString.prefix(8))
        try SessionPaths.secureDirectory(root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testStartupWaitsForLockRelease() throws {
        let root = try directory()
        var held: DeviceLock? = try DeviceLock(root: root, device: "startup")
        let started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        var failure: Error?
        DispatchQueue.global().async {
            started.signal()
            do {
                let lock = try PreviewServiceClient.startupLock(directory: root, timeout: 2)
                withExtendedLifetime(lock) {}
            } catch { failure = error }
            finished.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .timedOut)
        withExtendedLifetime(held) {}
        held = nil
        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        XCTAssertNil(failure)
    }

    func testStartupLockWaitIsBoundedAndDeviceLockRemainsExclusive() throws {
        let root = try directory(), held = try DeviceLock(root: root, device: "startup")
        defer { withExtendedLifetime(held) {} }
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try PreviewServiceClient.startupLock(directory: root, timeout: 0.1)) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "preview_service_busy")
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        XCTAssertThrowsError(try DeviceLock(root: root, device: "startup")) {
            XCTAssertEqual(($0 as? IPhoneUseError)?.code, "device_busy")
        }
    }

    func testConcurrentDirectoryCreationHasPrivatePermissionsFromTheStart() throws {
        let root = try directory(), leaf = root.appendingPathComponent("new/previews/8765")
        let lock = NSLock()
        var failures: [Error] = []
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            do { try SessionPaths.secureDirectory(leaf) } catch {
                lock.lock(); failures.append(error); lock.unlock()
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        for suffix in ["new", "new/previews", "new/previews/8765"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(suffix).path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
    }

    func testDirectoryCreationStillRejectsUnsafeModesFilesAndSymlinks() throws {
        let root = try directory(), unsafe = root.appendingPathComponent("unsafe")
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        for rejected in [unsafe, link, file] {
            XCTAssertThrowsError(try SessionPaths.secureDirectory(rejected)) {
                XCTAssertEqual(($0 as? IPhoneUseError)?.code, "unsafe_state_directory")
            }
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: unsafe.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        let dangling = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling,
                                                  withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try SessionPaths.secureDirectory(dangling.appendingPathComponent("child")))
    }

    func testIdleShutdownFencesRequestsButActivityBeforeDeadlinePreventsIt() throws {
        let service = try PreviewService(directory: directory(), port: 0)
        let auth: [String: Any] = ["authorization": service.registry.authorization, "version": 1]
        service.queue.sync {
            service.lastActivity = 0
            service.stopIfIdle(now: 600)
            XCTAssertFalse(service.isStopping)
            var ping = auth; ping["op"] = "ping"
            XCTAssertEqual(service.control(ping)["ok"] as? Bool, true)
            service.stopIfIdle(now: service.lastActivity + 1)
            XCTAssertFalse(service.isStopping)
            service.stopIfIdle(now: service.lastActivity + 601)
            XCTAssertTrue(service.isStopping)
            let error = service.control(ping)["error"] as? [String: Any]
            XCTAssertEqual(error?["code"] as? String, "preview_service_stopping")
        }
    }
}
