import Foundation
import CoreGraphics
import ImageIO
import AppleNativeBridge

final class AppleDeviceCLI {
    let device: String
    let cancellation: NativeCancellation
    private let reader: (([String]) throws -> [String: Any])?
    var captureSourcePolicy: [String: Any] {
        ["strategy": "coredevice_only"]
    }
    init(
        device: String, cancellation: NativeCancellation, reader: (([String]) throws -> [String: Any])? = nil
    ) {
        self.device = device; self.cancellation = cancellation; self.reader = reader
    }
    func read(
        _ arguments: [String], trailingArguments: [String] = [], timeout: Int = 20,
        budget: NativeCaptureBudget? = nil
    ) throws -> [String: Any] {
        try cancellation.check()
        try budget?.check()
        do {
            let result: [String: Any]
            if let reader {
                result = try reader(arguments)
            } else {
                result = try CoreDevice.read(
                    arguments + ["--device", device],
                    cancelled: {
                        self.cancellation.isCancelled
                            || budget.map { ProcessInfo.processInfo.systemUptime >= $0.deadline } == true
                    }, trailingArguments: trailingArguments, timeout: timeout)
            }
            try cancellation.check()
            try budget?.check()
            return result
        } catch {
            do {
                try cancellation.check()
                try budget?.check()
            } catch let deadlineError as IPhoneUseError {
                throw IPhoneUseError(
                    deadlineError.code, deadlineError.description,
                    diagnostics: (error as? IPhoneUseError)?.diagnostics ?? [:])
            }
            throw error
        }
    }
    func display() throws -> NativeDisplay { try NativeDisplay(read(["device", "info", "displays"])) }
    func capture(
        generation: String, budget: NativeCaptureBudget? = nil,
        prepareDisplay: (NativeDisplay) throws -> Void = { _ in },
        validateDisplay: (NativeDisplay, Double) throws -> [String: Any] = { _, _ in [:] }
    ) throws -> CapturedObservation {
        try AppleCaptureAttempt(cli: self, generation: generation, budget: budget)
            .run(prepareDisplay: prepareDisplay, validateDisplay: validateDisplay)
    }
}
