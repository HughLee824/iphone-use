import Foundation

// Shared with the device Runner. This is an internal XCTest key, not a public API.
@MainActor
enum XCTestDiagnostics {
    static func withoutAutomaticSpindump<T>(defaults: UserDefaults = .standard,
                                            _ operation: () throws -> T) rethrows -> T {
        let name = UserDefaults.argumentDomain
        let key = "XCTDisableSpindump"
        var arguments = defaults.volatileDomain(forName: name)
        let previous = arguments[key]
        arguments[key] = true
        defaults.setVolatileDomain(arguments, forName: name)
        defer {
            // Restore only our key; preserve unrelated changes made during the operation.
            var current = defaults.volatileDomain(forName: name)
            current[key] = previous
            defaults.setVolatileDomain(current, forName: name)
        }
        return try operation()
    }
}
