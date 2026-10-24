import Network
import XCTest
import Darwin

// These XCTest symbols are runtime capabilities, not a public API or a linked WDA dependency.
struct XCTestStateTimeout {
    private typealias Getter = @convention(c) () -> Double
    private typealias Setter = @convention(c) (Double) -> Void
    private let get: Getter
    private let set: Setter

    init?() {
        let symbols = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let getter = dlsym(symbols, "_XCTApplicationStateTimeout"),
            let setter = dlsym(symbols, "_XCTSetApplicationStateTimeout")
        else { return nil }
        get = unsafeBitCast(getter, to: Getter.self)
        set = unsafeBitCast(setter, to: Setter.self)
    }

    // All callers are synchronous on the Runner's main actor; always restore XCTest's setting.
    func perform(_ body: () throws -> Void) rethrows {
        let previous = get()
        set(1)
        defer { set(previous) }
        try body()
    }
}
