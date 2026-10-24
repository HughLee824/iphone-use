import Foundation

public struct IdleTimeout: Equatable {
    public let seconds: TimeInterval

    public init(_ value: String) throws {
        let multiplier: Double
        switch value.last {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 3600
        default:
            throw IPhoneUseError("invalid_idle_timeout", "Use a positive duration such as 30m, 60m or 10s")
        }
        guard let number = Double(value.dropLast()), number.isFinite, number > 0,
            (number * multiplier).isFinite
        else {
            throw IPhoneUseError("invalid_idle_timeout", "Idle timeout must be positive and finite")
        }
        seconds = number * multiplier
    }
}
