import Foundation

extension HostRequestExecution {
    func prepareText() throws {
        // Bind preparation to a fresh observation, even when the borrowed
        // CoreDevice keyboard is already ready. Preparation does not focus a field.
        previousObservation = observations.beginAction()
        effective = true
        response["result"] = try backend.prepareText()
        observations.finishAction(previous: previousObservation, dispatched: true)
        response["outcome"] = "completed"
        response["requiresObservation"] = true
    }

    func finishText() throws {
        let metadata = try observations.resolveTextConfirmation(
            reference!, nativeOnly: config.backend == "apple-native")
        if let raw = metadata["textObservationOptions"] as? [String: Any] {
            textObservationOptions = try JSONDecoder().decode(
                NativeTextObservationOptions.self, from: jsonData(raw))
        }
        let transaction = validatedValue(request["transaction"], as: String.self)
        let result: [String: Any]
        if touchPaste.pending || touchPaste.owns(transaction) {
            result = try touchPaste.finish(
                transaction: transaction,
                observedAt: validatedValue(metadata["hostStoredAtUptime"], as: Double.self))
        } else {
            guard config.backend == "apple-native" else {
                throw IPhoneUseError(
                    "invalid_text_transaction",
                    "No matching touch-paste transaction exists in this Runner session")
            }
            result = try backend.finishText(transaction: transaction, observation: metadata)
        }
        response["result"] = result
        effective = true
        let restored = result["pasteboardRestoreAcknowledged"] as? Bool == true
        response["ok"] = restored
        response["outcome"] = restored ? "completed" : "unknown"
        response["requiresObservation"] = true
        if !restored {
            response["error"] = [
                "code": "native_pasteboard_restore_unconfirmed",
                "message":
                    """
                Clipboard restoration was not confirmed; no restorative write will be replayed.\
                 Inspect clipboard status and close the session.
                """
            ]
        }
    }

    func performAction() throws {
        if action!.touchPaste {
            _ = try observations.resolveTextConfirmation(action!.reference, nativeOnly: false)
            if config.backend == "apple-native",
                let pasteboard = try backend.status()["pasteboard"] as? [String: Any],
                pasteboard["restorePending"] as? Bool == true
                    || pasteboard["writeUncertain"] as? Bool == true {
                throw IPhoneUseError(
                    "native_pasteboard_pending",
                    "Finish the existing native clipboard transaction before touch-paste")
            }
            previousObservation = observations.beginAction()
            effective = true
            response["result"] = try touchPaste.stage(
                validatedValue(action!.fields["text"], as: String.self),
                observation: action!.reference.observation)
            observations.finishAction(previous: previousObservation, dispatched: true)
            response["outcome"] = "prepared"
            response["requiresObservation"] = true
            return
        }
        let target = try observations.resolveTarget(for: action!)
        if config.backend == "apple-native", let raw = target.context["screenContext"] as? [String: Any] {
            postActionSourceContext = try JSONDecoder().decode(ScreenContext.self, from: jsonData(raw))
        }
        if ["type", "press"].contains(action!.kind), let field = action!.textRegion {
            textObservationOptions = NativeTextObservationOptions(
                field: field, ignoring: action!.ignoredScreenRect)
        }
        previousObservation = observations.beginAction()
        effective = true
        let previewGesture = NativePreviewGesture(
            action: action!, target: target,
            previewRotation: backend.previewGestureRotation)
        response["result"] = try backend.perform(action!, target: target) { [backend] in
            // The backend signals only after validation, at input dispatch.
            // A later failure must not delay or replay this visual receipt.
            if let gesture = previewGesture { backend.showPreviewGesture(gesture) }
        }
        observations.finishAction(previous: previousObservation, dispatched: true)
        response["outcome"] = "completed"
        if config.backend == "apple-native",
            (response["result"] as? [String: Any])?["transportStatus"] as? String == "sent" {
            // RemoteXPC's send barrier is not a device execution acknowledgement.
            response["outcome"] = "unknown"
            response["ok"] = false
            response["requiresObservation"] = true
            response["error"] = [
                "code": "native_input_unacknowledged",
                "message":
                    "Input reports were queued; inspect the new screenshot to judge the result. Input was not replayed."
            ]
        }
    }
}
