import Foundation

// Use only for internal values whose type was established by an earlier validation
// step. A violation is a programming error, rather than a recoverable device error.
func validatedValue<Value>(_ value: Any?, as type: Value.Type) -> Value {
    guard let value = value as? Value else {
        preconditionFailure("Previously validated value must have type \(type)")
    }
    return value
}
