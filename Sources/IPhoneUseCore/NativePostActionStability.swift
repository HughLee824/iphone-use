import Foundation

// Post-input readiness only. This never authorizes input or replaces its baseline.
// Apple captures are slower than Runner captures, so use a separate total deadline.
enum NativePostActionStability {
    static let timeout: TimeInterval = 15
    static let minimumDuration: TimeInterval = 1.5
    static let stableDuration: TimeInterval = 0.4
    static let requiredFrames = 3
    // Readiness only: permit a tiny bounded animation, without identifying it
    // as a caret or carrying this tolerance into input authorization.
    static let maximumChangedFraction = 0.001
    static let maximumLocalArea = 320.0 // square screen points
    static let maximumLocalDimension = 80.0

    static func localizedChangeBounds(_ comparison: FrameComparison, frame: FrameFingerprint,
                                      screen: ScreenRect, previous: CGRect?) -> CGRect? {
        guard comparison.dimensionsMatch, let pixels = comparison.changedBounds,
              Double(comparison.changedPixels) / Double(frame.width * frame.height) <= maximumChangedFraction else {
            return nil
        }
        let scaleX = screen.width / Double(frame.width), scaleY = screen.height / Double(frame.height)
        let points = CGRect(x: screen.x + pixels.minX * scaleX, y: screen.y + pixels.minY * scaleY,
                            width: pixels.width * scaleX, height: pixels.height * scaleY)
        // Accumulate the spatial envelope against the same anchor; do not let
        // a succession of tiny changes move a tolerance window across the UI.
        let bounds = previous.map { $0.union(points) } ?? points
        guard bounds.width <= maximumLocalDimension, bounds.height <= maximumLocalDimension,
              bounds.width * bounds.height <= maximumLocalArea else { return nil }
        return bounds
    }

    static func capture(ignoring: ScreenRect? = nil, sourceContext: ScreenContext? = nil,
                        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                        pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                        checkCancellation: () throws -> Void,
                        sample: (TimeInterval) throws -> CapturedObservation) throws -> CapturedObservation {
        let started = now(), deadline = started + timeout
        var anchor: FrameFingerprint?, anchorContext: ScreenContext?, anchorIdentity: Data?
        var latest: CapturedObservation?, latestHash: String?
        var comparison: [String: Any]?
        var unchangedSince = started, lastSampleAt = started, consecutive = 0, samples = 0, attempts = 0
        var lastError: String?, stable = false
        var geometrySamples = 0
        var lastCaptureDiagnostics: [String: Any] = [:]
        var captureSamples: [[String: Any]] = []
        var exclusionContext = sourceContext
        var exclusionInvalidated = false
        var localBounds: CGRect?
        var localChangeComparisons = 0
        while now() < deadline {
            try checkCancellation()
            let began = now()
            attempts += 1
            let frame: CapturedObservation
            do {
                frame = try sample(deadline)
            } catch let error as IPhoneUseError where [
                "capture_timeout", "input_preflight_timeout", "coredevice_timeout"
            ].contains(error.code) {
                lastError = "capture_deadline_exceeded"
                lastCaptureDiagnostics = error.diagnostics
                captureSamples.append([
                    "attempt": attempts, "elapsedMs": (now() - began) * 1000, "errorCode": error.code
                ])
                break
            } catch let error as IPhoneUseError where error.code == "capture_context_changed" {
                // Rotation during acquisition is not a stable sample. Keep the
                // total deadline and require a new run of consistent frames.
                lastError = error.code
                lastCaptureDiagnostics = error.diagnostics
                captureSamples.append([
                    "attempt": attempts, "elapsedMs": (now() - began) * 1000, "errorCode": error.code
                ])
                anchor = nil; anchorContext = nil; anchorIdentity = nil; consecutive = 0
                exclusionInvalidated = true; geometrySamples = 0
                pause(min(0.2, max(0, deadline - now())))
                continue
            }
            try checkCancellation()
            captureSamples.append(["attempt": attempts, "elapsedMs": (now() - began) * 1000,
                                   "captureTimingsMs": frame.metadata["captureTimingsMs"] ?? [:]])
            guard frame.metadata["captureSource"] as? String == "coredevice_screenshot",
                  let raw = frame.metadata["screenContext"] as? [String: Any] else {
                throw IPhoneUseError(
                    "invalid_action_frame", "Post-action stability requires an Apple PNG and screen context"
                )
            }
            let context = try JSONDecoder().decode(ScreenContext.self, from: jsonData(raw))
            guard context.valid else {
                throw IPhoneUseError("invalid_action_frame", "Invalid post-action display context")
            }
            let identity = try jsonData(frame.metadata.filter {
                ["deviceID", "sessionGeneration", "displayID", "displayRotation", "nativeRotation"].contains($0.key)
            })
            let fingerprint = try FrameFingerprint(png: frame.screenshot)
            latest = frame; latestHash = fingerprint.hash; samples += 1
            if frame.metadata["orientationResynchronized"] as? Bool == true {
                anchor = nil; anchorContext = nil; anchorIdentity = nil; consecutive = 0
                exclusionInvalidated = true
            }
            if exclusionContext == nil { exclusionContext = context }
            if exclusionContext?.matches(context) != true { exclusionInvalidated = true }
            let mask = exclusionInvalidated ? nil : ignoring
            if let mask, !context.screen.cgRect.contains(mask.cgRect) {
                throw IPhoneUseError("invalid_ignored_region", "Post-action exclusion is outside the screen")
            }
            let sameGeometry = anchorContext?.matches(context) == true && anchorIdentity == identity
            geometrySamples = sameGeometry ? geometrySamples + 1 : 1
            let match = anchor.map { FrameComparison(reference: $0, current: fingerprint,
                                                     ignoredCaret: mask, screen: context.screen) }
            let toleratedBounds = sameGeometry ? match.flatMap {
                localizedChangeBounds($0, frame: fingerprint, screen: context.screen, previous: localBounds)
            } : nil
            let readinessEquivalent = sameGeometry && (match?.equivalent == true || toleratedBounds != nil)
            comparison = match?.result
            comparison?.removeValue(forKey: "ignoredCaret")
            comparison?["geometryMatches"] = sameGeometry
            comparison?["readinessEquivalent"] = readinessEquivalent
            comparison?["localizedChangeTolerated"] = toleratedBounds != nil
            if let mask { comparison?["ignoredRect"] = try jsonObject(JSONEncoder().encode(mask)) }
            let finished = now()
            lastSampleAt = finished
            if readinessEquivalent {
                consecutive += 1
                if let toleratedBounds { localBounds = toleratedBounds; localChangeComparisons += 1 }
            } else {
                // Compare against a fixed anchor: small drift must accumulate.
                anchor = fingerprint; anchorContext = context; anchorIdentity = identity
                unchangedSince = finished; consecutive = 1
                localBounds = nil; localChangeComparisons = 0
            }
            stable = finished < deadline && consecutive >= requiredFrames
                && finished - unchangedSince >= stableDuration && finished - started >= minimumDuration
            if stable || (geometrySamples >= requiredFrames && finished - started >= minimumDuration) { break }
            pause(min(max(0, 0.2 - (now() - began)), max(0, deadline - now())))
        }
        try checkCancellation()
        guard let latest else {
            throw IPhoneUseError(
                "post_action_capture_timeout",
                "Input was not replayed; no valid post-action screenshot was acquired before the deadline",
                diagnostics: ["reason": "no_valid_sample", "samples": samples, "attempts": attempts,
                    "elapsedMs": (now() - started) * 1000, "timeoutMs": timeout * 1000,
                    "captureSamples": captureSamples, "lastCaptureDiagnostics": lastCaptureDiagnostics])
        }
        var metadata = latest.metadata
        let reason: String
        if stable {
            reason = "stable"
        } else if comparison?["readinessEquivalent"] as? Bool == false {
            reason = "dynamic_or_transitioning"
        } else if consecutive < requiredFrames {
            reason = "insufficient_stable_samples"
        } else {
            reason = "observation_deadline_exceeded"
        }
        metadata["postActionStability"] = [
            "stable": stable, "reason": reason,
            "algorithm": "apple-png-yiq-local-readiness-v2", "samples": samples, "attempts": attempts,
            "consecutiveFrames": consecutive, "requiredFrames": requiredFrames,
            "elapsedMs": (now() - started) * 1000, "timeoutMs": timeout * 1000,
            "minimumObservationMs": minimumDuration * 1000, "requiredStableMs": stableDuration * 1000,
            "stableForMs": consecutive > 0 ? max(0, lastSampleAt - unchangedSince) * 1000 : 0,
            "frameHash": latestHash as Any? ?? NSNull(), "comparison": comparison as Any? ?? NSNull(),
            "localizedChange": ["comparisons": localChangeComparisons,
                "maximumChangedFraction": maximumChangedFraction, "maximumAreaPoints": maximumLocalArea,
                "maximumDimensionPoints": maximumLocalDimension,
                "boundsPoints": localBounds.map {
                    ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height]
                } as Any? ?? NSNull()],
            "lastCaptureError": lastError as Any? ?? NSNull(), "lastCaptureDiagnostics": lastCaptureDiagnostics,
            "captureSamples": captureSamples, "exclusionInvalidated": exclusionInvalidated,
            "automaticReplayAllowed": false
        ]
        return CapturedObservation(nodes: latest.nodes, metadata: metadata, screenshot: latest.screenshot)
    }
}
