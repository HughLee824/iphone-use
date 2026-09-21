import XCTest
@testable import AgentSomaCore

private final class AppProcessFixture {
    let bundle = "com.example.probe"
    let app = "file:///private/var/containers/Bundle/Application/fixture/Probe.app/"
    var rows: [[String: Any]] = []
    var calls: [[String]] = []
    var clock = 0.0
    var cancelled = false
    var failTerminate = false
    var failLaunch = false
    var ignoreTerminate = false
    var onProcesses: ((Int) -> Void)?
    var onTerminate: (() -> Void)?
    var onLaunch: (() -> Void)?
    var processReads = 0
    var replacementApp: String?
    var appReads = 0

    func process(_ pid: Int, _ suffix: String = "Probe") -> [String: Any] {
        ["processIdentifier": pid, "executable": app + suffix]
    }
    var engine: NativeAppLifecycle {
        NativeAppLifecycle(read: { args, tail, timeout in
            XCTAssertGreaterThan(timeout, 0); XCTAssertLessThanOrEqual(timeout, 5)
            self.calls.append(args + tail)
            switch Array(args.prefix(3)) {
            case ["device", "info", "apps"]:
                self.appReads += 1
                return ["apps": [["bundleIdentifier": self.bundle, "url": self.appReads > 1 ? self.replacementApp ?? self.app : self.app]]]
            case ["device", "info", "processes"]:
                self.processReads += 1; self.onProcesses?(self.processReads)
                return ["runningProcesses": self.rows]
            case ["device", "process", "terminate"]:
                XCTAssertEqual(args, ["device", "process", "terminate", "--pid", "100"])
                if !self.ignoreTerminate { self.rows.removeAll { $0["processIdentifier"] as? Int == 100 } }
                self.onTerminate?()
                if self.failTerminate { throw SomaError("coredevice_timeout", "Lost termination reply") }
                return [:]
            case ["device", "process", "launch"]:
                XCTAssertEqual(args, ["device", "process", "launch", "--activate"])
                XCTAssertEqual(tail, [self.bundle])
                self.rows.append(self.process(101)); self.onLaunch?()
                if self.failLaunch { throw SomaError("coredevice_timeout", "Lost launch reply") }
                return ["process": self.process(101)]
            default: XCTFail("Unexpected command"); return [:]
            }
        }, checkCancellation: {
            if self.cancelled { throw SomaError("native_cancelled", "Cancelled") }
        }, now: { self.clock }, sleep: { self.clock += $0 })
    }
    var mutations: [[String]] { calls.filter { $0[1] == "process" } }
}

final class NativeAppLifecycleTests: XCTestCase {
    func testAppleCLITimeoutUsesIntegerSeconds() {
        for seconds in [5, 20] {
            let args = CoreDevice.commandArguments(["list", "devices"], output: URL(fileURLWithPath: "/tmp/result.json"), timeout: seconds)
            XCTAssertEqual(args[args.firstIndex(of: "--timeout")! + 1], String(seconds))
        }
    }

    func testRelaunchRequiresExitThenNewMatchingPIDAndNeverClaimsForeground() throws {
        let f = AppProcessFixture()
        f.rows = [f.process(100), f.process(200, "PlugIns/Probe.appex/Probe"), f.process(201, "Frameworks/Helper")]
        let result = try f.engine.run(bundle: f.bundle, relaunch: true)
        XCTAssertEqual(result["previousPID"] as? Int, 100)
        XCTAssertEqual(result["newPID"] as? Int, 101)
        XCTAssertEqual(result["oldProcessAbsentConfirmed"] as? Bool, true)
        XCTAssertEqual(result["newProcessObserved"] as? Bool, true)
        XCTAssertEqual(result["foregroundConfirmed"] as? Bool, false)
        XCTAssertEqual(f.mutations.count, 2)
        XCTAssertEqual(f.rows.compactMap { $0["processIdentifier"] as? Int }, [200, 201, 101])
    }

    func testAlreadyStoppedTerminationDoesNotSignalAndRelaunchOnlyLaunches() throws {
        for relaunch in [false, true] {
            let f = AppProcessFixture()
            let result = try f.engine.run(bundle: f.bundle, relaunch: relaunch)
            XCTAssertEqual(result["alreadyStopped"] as? Bool, true)
            XCTAssertEqual(result["terminationRequested"] as? Bool, false)
            XCTAssertEqual(f.mutations.count, relaunch ? 1 : 0)
        }
    }

    func testIdentityChangeBeforeSignalRejectsWithoutKillingReplacement() throws {
        let f = AppProcessFixture(); f.rows = [f.process(100)]
        f.onProcesses = { if $0 == 2 { f.rows = [f.process(101)] } }
        XCTAssertThrowsError(try f.engine.run(bundle: f.bundle, relaunch: true)) {
            XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, false)
            XCTAssertEqual(($0 as? ActionFailure)?.code, "native_app_process_changed")
            XCTAssertEqual(($0 as? ActionFailure)?.requiresObservation, true)
        }
        XCTAssertTrue(f.mutations.isEmpty)
    }

    func testLostTerminationOrLaunchReplyStopsWithoutReplay() {
        for termination in [true, false] {
            let f = AppProcessFixture(); f.rows = [f.process(100)]
            f.failTerminate = termination; f.failLaunch = !termination
            XCTAssertThrowsError(try f.engine.run(bundle: f.bundle, relaunch: true)) {
                let failure = $0 as? ActionFailure
                XCTAssertEqual(failure?.possiblyExecuted, true)
                XCTAssertEqual(failure?.result?["launchRequested"] as? Bool, !termination)
                XCTAssertEqual(failure?.result?["terminationAcknowledged"] as? Bool, !termination)
            }
            XCTAssertEqual(f.mutations.count, termination ? 1 : 2)
        }
    }

    func testUnconfirmedExitIsBoundedAndDoesNotLaunchOrEscalateSignal() {
        let f = AppProcessFixture(); f.rows = [f.process(100)]; f.ignoreTerminate = true
        XCTAssertThrowsError(try f.engine.run(bundle: f.bundle, relaunch: true)) {
            XCTAssertEqual(($0 as? ActionFailure)?.code, "native_app_exit_unconfirmed")
            XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, true)
        }
        XCTAssertLessThan(f.clock, 6); XCTAssertEqual(f.mutations.count, 1)
    }

    func testCancellationBeforeAndAfterTerminationNeverLaunches() {
        for before in [true, false] {
            let f = AppProcessFixture(); f.rows = [f.process(100)]; f.cancelled = before
            f.onTerminate = { f.cancelled = true }
            XCTAssertThrowsError(try f.engine.run(bundle: f.bundle, relaunch: true)) {
                XCTAssertEqual(($0 as? ActionFailure)?.possiblyExecuted, !before)
                XCTAssertEqual(($0 as? ActionFailure)?.code, "native_cancelled")
            }
            XCTAssertEqual(f.mutations.count, before ? 0 : 1)
        }
    }

    func testExternalRestartAndReinstallStopRelaunch() {
        let f = AppProcessFixture(); f.rows = [f.process(100)]
        f.onTerminate = { f.rows = [f.process(102)] }
        XCTAssertThrowsError(try f.engine.run(bundle: f.bundle, relaunch: true)) {
            XCTAssertEqual(($0 as? ActionFailure)?.result?["oldProcessAbsentConfirmed"] as? Bool, true)
        }
        XCTAssertEqual(f.mutations.count, 1)
        let g = AppProcessFixture(); g.replacementApp = "file:///different/Probe.app/"
        XCTAssertThrowsError(try g.engine.run(bundle: g.bundle, relaunch: true))
        XCTAssertTrue(g.mutations.isEmpty)
    }

    func testUnobservedNewProcessPreservesPartialFacts() {
        let f = AppProcessFixture(); f.rows = [f.process(100)]
        f.onLaunch = { f.rows = [] }
        XCTAssertThrowsError(try f.engine.run(bundle: f.bundle, relaunch: true)) {
            let failure = $0 as? ActionFailure
            XCTAssertEqual(failure?.result?["launchAcknowledged"] as? Bool, true)
            XCTAssertEqual(failure?.result?["newProcessObserved"] as? Bool, false)
            XCTAssertEqual(failure?.possiblyExecuted, true)
        }
        XCTAssertEqual(f.mutations.count, 2)
    }

    func testRejectsAmbiguousMissingAndMalformedIdentities() throws {
        let f = AppProcessFixture(); f.rows = [f.process(100), f.process(101)]
        XCTAssertThrowsError(try f.engine.run(bundle: f.bundle, relaunch: true))
        XCTAssertTrue(f.mutations.isEmpty)
        XCTAssertThrowsError(try f.engine.run(bundle: "com.example.other", relaunch: true))
        XCTAssertTrue(f.mutations.isEmpty)
        for pid in [true, 0, -1, 2.5, "100", Int64(Int32.max) + 1] as [Any] {
            XCTAssertThrowsError(try NativeAppProcess.list(["runningProcesses": [["processIdentifier": pid, "executable": f.app + "Probe"]]]))
        }
        XCTAssertThrowsError(try NativeAppProcess.list([:]))
        XCTAssertThrowsError(try NativeAppProcess.list(["runningProcesses": [f.process(100), f.process(100)]]))
        for url in ["https://host/Probe.app", "file://foreign/Probe.app", "Probe.app", "file:///Probe.app?query"] {
            XCTAssertThrowsError(try NativeAppProcess.fileURL(url))
        }
        let rows = try NativeAppProcess.list(["runningProcesses": [["processIdentifier": 1, "executable": "file:///sbin/launchd"],
            f.process(100, "PlugIns/Other.appex/Probe")]])
        XCTAssertNil(try NativeAppProcess.target(in: rows, app: NativeAppProcess.fileURL(f.app)))
    }
}
