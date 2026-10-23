import Foundation

extension HostRequest {
    func validateTextBackend() -> Bool {
        if operation == "text-prepare", config.backend != "apple-native" {
            reject("native_action_unsupported", "text-prepare applies only to apple-native")
            return false
        }
        return true
    }
    func validateTextScope() -> Bool {
        if requestedOperation == "text-prepare-scoped"
            || (operation == "text-prepare" && (request["fieldRect"] != nil || request["ignoreRect"] != nil)) {
            do { textObservationOptions = try NativeTextObservationOptions(request: request) } catch {
                reject((error as? IPhoneUseError)?.code ?? "invalid_text_region", String(describing: error))
                return false
            }
        }
        return true
    }
    func validateTextMethod() -> Bool {
        if ["type-with-caret", "press-with-caret"].contains(requestedOperation), request["caretRect"] == nil {
            reject("invalid_caret_region", "Explicit caret requests require --caret-rect")
            return false
        }
        if requestedOperation == "type-with-method", request["textMethod"] == nil {
            reject("invalid_text_method", "Explicit text requests require a method")
            return false
        }
        return true
    }
    func validateTextFinish() -> Bool {
        if operation == "text-finish" {
            do {
                guard let transaction = request["transaction"] as? String,
                    UUID(uuidString: transaction) != nil
                else {
                    throw IPhoneUseError(
                        "invalid_text_transaction", "text-finish requires a pasteboard transaction ID")
                }
                reference = try ObservationReference(request["reference"] as? String ?? "")
                guard reference?.node == nil else {
                    throw IPhoneUseError("invalid_reference", "Use the current screenshot oN")
                }
            } catch {
                reject((error as? IPhoneUseError)?.code ?? "invalid_request", String(describing: error))
                return false
            }
        }
        return true
    }
    func validateAction() -> Bool {
        if DeviceAction.operations.contains(operation) {
            do {
                action = try DeviceAction(
                    operation: operation, request: request, allowScreenText: config.backend == "apple-native")
            } catch {
                reject((error as? IPhoneUseError)?.code ?? "invalid_action", String(describing: error))
                return false
            }
        }
        return true
    }
    func validateInspection() -> Bool {
        if operation == "inspect" {
            do {
                reference = try ObservationReference(request["reference"] as? String ?? "")
                guard let offset = request["offset"] as? Int, offset >= 0 else {
                    throw IPhoneUseError("invalid_offset", "A nonnegative offset is required")
                }
                guard request["query"] == nil || request["query"] is String else {
                    throw IPhoneUseError("invalid_inspect_query", "Query must be text")
                }
            } catch {
                reject((error as? IPhoneUseError)?.code ?? "invalid_reference", String(describing: error))
                return false
            }
        }
        return true
    }
}
