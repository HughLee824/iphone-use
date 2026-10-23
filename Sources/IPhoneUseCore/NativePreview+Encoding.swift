import Foundation
import Network
import CoreImage
import ImageIO

extension NativePreview {

    func encodeLatest() {
        let started = ProcessInfo.processInfo.systemUptime
        let tickGap = lastTick.map { (started - $0) * 1000 } ?? 0
        lastTick = started; maxTickGapMs = max(maxTickGapMs, tickGap)
        // A listener or live transport is not proof of usable video. Bound the
        // initial wait; a quiet screen keeps its already validated last frame.
        if !closed, let firstFrameDeadline, started >= firstFrameDeadline, error == nil {
            error = "No valid video frame received within 3 seconds"
        }
        guard !closed, !contexts.isEmpty, let receiver, let display,
            receiver.health()["healthy"] as? Bool == true
        else { return }
        guard let frame = receiver.snapshots?.previewFrame(includeReducedResolution: true) else {
            if let failure = receiver.snapshots?.status()["lastError"] as? String {
                error = failure; jpeg = nil
            }
            return
        }
        guard frame.completedAt != lastSubmittedFrameAt else { return }
        let admittedAt = ProcessInfo.processInfo.systemUptime
        let sourceReadMs = (admittedAt - started) * 1000
        let generation = bindingGeneration
        let context = contexts.removeLast()
        lastSubmittedFrameAt = frame.completedAt
        // Two bounded slots let a fresh frame bypass one slow conversion.
        // Timer ticks while both are busy are skipped, never queued.
        encoderQueue.async { [self] in
            let encodingStarted = ProcessInfo.processInfo.systemUptime
            let result = Result { try autoreleasepool { try encodeFrame(frame, display, context) } }
            let encodeMs = (ProcessInfo.processInfo.systemUptime - encodingStarted) * 1000
            let workerWaitMs = (encodingStarted - admittedAt) * 1000
            queue.async { [self] in
                contexts.append(context)
                guard !closed, bindingGeneration == generation else { return }
                completeEncode(
                    result, frame: frame, display: display,
                    timing: EncodeTiming(
                        encodeMs: encodeMs, tickGap: tickGap, sourceReadMs: sourceReadMs,
                        workerWaitMs: workerWaitMs, encodingStarted: encodingStarted))
            }
        }
    }

    private struct EncodeTiming {
        let encodeMs: Double
        let tickGap: Double
        let sourceReadMs: Double
        let workerWaitMs: Double
        let encodingStarted: Double
    }

    private func completeEncode(
        _ result: Result<EncodedJPEG, Error>, frame: NativeVideoSnapshot.Frame,
        display: NativeDisplay, timing: EncodeTiming
    ) {
        maxEncodeMs = max(maxEncodeMs, timing.encodeMs)
        if timing.tickGap > 100 || timing.encodeMs > 100 || timing.sourceReadMs > 100
            || timing.workerWaitMs > 100 {
            slowFrames.append([
                "wallTime": Date().timeIntervalSince1970, "tickGapMs": timing.tickGap,
                "encodeMs": timing.encodeMs, "sourceReadMs": timing.sourceReadMs,
                "workerWaitMs": timing.workerWaitMs,
                "sourceAgeMs": (timing.encodingStarted - frame.completedAt) * 1000
            ])
            if slowFrames.count > 120 { slowFrames.removeFirst() }
        }
        if let frameAt, frame.completedAt <= frameAt { discardedEncodes += 1; return }
        switch result {
        case .success(let encoded):
            jpegActiveWidth = frame.image.activeWidth; jpegActiveHeight = frame.image.activeHeight
            jpeg = encoded.data; jpegRotation = display.rotation; frameAt = frame.completedAt
            lastEncodeMs = timing.encodeMs; encodedFrames += 1; error = nil; firstFrameDeadline = nil
        case .failure(let failure):
            error = String(describing: failure); jpeg = nil
            if lastSubmittedFrameAt == frame.completedAt { lastSubmittedFrameAt = nil }
        }
        // Publish before another encode; HTTP and health never wait
        // behind image conversion or a file decoder's GPU workload.
        flushWaiting()
    }

    static func encode(
        _ frame: NativeVideoSnapshot.Frame, display: NativeDisplay, context: CIContext = CIContext()
    )
        throws -> Data {
        try encodeJPEG(frame, display: display, context: context).data
    }

    static func encodeJPEG(_ frame: NativeVideoSnapshot.Frame, display: NativeDisplay, context: CIContext)
        throws -> EncodedJPEG {
        let native = try NativeSnapshotImage.validateGeometry(
            frame, display: display, allowReducedResolution: true)
        let pixels = frame.pixels
        // VRA scales the entire encoded canvas, including its right/bottom
        // padding, into the top-left active rectangle. Crop the proportional
        // native rectangle before restoring its axes; stretching the entire
        // active rectangle would include padding and shift screen landmarks.
        let scaleX = Double(CVPixelBufferGetWidth(pixels)) / Double(frame.image.activeWidth)
        let scaleY = Double(CVPixelBufferGetHeight(pixels)) / Double(frame.image.activeHeight)
        let nativeWidth = Double(native.width) / scaleX
        let nativeHeight = Double(native.height) / scaleY
        // CI coordinates start at the bottom, pixel-buffer rows at the top.
        var image = CIImage(cvPixelBuffer: pixels).cropped(
            to: CGRect(
                x: 0,
                y: Double(CVPixelBufferGetHeight(pixels)) - nativeHeight,
                width: nativeWidth, height: nativeHeight))
        image = image.transformed(
            by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY)
        )
        .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        if display.rotation == "rot90" { image = image.oriented(.right) }
        if display.rotation == "rot270" { image = image.oriented(.left) }
        let scale = min(1, 960 / max(image.extent.width, image.extent.height))
        let output = CGRect(
            x: 0, y: 0, width: min(960, ceil(image.extent.width * scale)),
            height: min(960, ceil(image.extent.height * scale)))
        // The short edge is often fractional (1170 × 960 / 2532 = 443.60).
        // Extend the validated native edge, not the decoder padding, before
        // resampling. Otherwise the last JPEG column composites partial alpha
        // against white, leaving a visible gray seam even on a black screen.
        image = image.clampedToExtent().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: output)
        // Let Core Image render directly for JPEG export instead of materializing
        // an RGBA CGImage and handing it to a separate ImageIO destination. Keep
        // color management, the native crop, output dimensions and quality intact.
        // Rendering and compression are fused: report their combined wall time,
        // never zero-valued timings pretending to measure the individual stages.
        guard
            let data = context.jpegRepresentation(
                of: image, colorSpace: CGColorSpaceCreateDeviceRGB(),
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7])
        else {
            throw IPhoneUseError("preview_encoding_failed", "JPEG encoding failed")
        }
        return EncodedJPEG(data: data)
    }
}
