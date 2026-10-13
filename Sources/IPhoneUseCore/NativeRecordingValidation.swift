import Foundation
import AVFoundation
import CoreVideo

enum NativeRecordingOptions {
    static func supported(by details: [String: Any]) -> Bool {
        (details["capabilities"] as? [[String: Any]])?.contains {
            $0["featureIdentifier"] as? String == "com.apple.coredevice.feature.screenrecording"
        } == true
    }

    static func duration(_ request: [String: Any]) throws -> Double {
        guard let value = request["duration"] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
              (1...300).contains(value.doubleValue) else {
            throw IPhoneUseError("invalid_recording_duration", "Recording duration must be 1–300 seconds")
        }
        return value.doubleValue
    }

}

enum NativeRecordingValidation {
    static func inspect(_ url: URL) throws -> [String: Any] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = attributes[.size] as? NSNumber, bytes.int64Value > 0 else {
            throw IPhoneUseError("recording_invalid", "Recording is not a nonempty regular file")
        }
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0, seconds <= 330,
              let track = asset.tracks(withMediaType: .video).first else {
            throw IPhoneUseError("recording_invalid", "Recording has no finite video duration/track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw IPhoneUseError("recording_invalid", "Video track cannot be decoded") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? IPhoneUseError("recording_invalid", "Cannot start video decoder") }
        defer { reader.cancelReading() }
        var count = 0, first = 0.0, last = -Double.infinity, width = 0, height = 0
        // A five-minute phone recording can contain thousands of full-size
        // frames. Keep full decoding, but scale its budget within the host's
        // 75-second command timeout (also allowing 10 seconds to finalize).
        let validationBudget = max(15, min(45, seconds / 5))
        let validationStarted = ProcessInfo.processInfo.systemUptime
        let deadline = validationStarted + validationBudget
        while let sample = output.copyNextSampleBuffer() {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  let pixels = CMSampleBufferGetImageBuffer(sample) else {
                throw IPhoneUseError("recording_validation_timeout", "Video validation exceeded its budget or returned no decoded image")
            }
            let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard time.isFinite, time >= last else { throw IPhoneUseError("recording_invalid", "Video timestamps are invalid") }
            if count == 0 { first = time; width = CVPixelBufferGetWidth(pixels); height = CVPixelBufferGetHeight(pixels) }
            last = time; count += 1
        }
        guard reader.status == .completed, count > 0, width > 0, height > 0 else {
            throw reader.error ?? IPhoneUseError("recording_invalid", "Video did not decode completely")
        }
        let transform = track.preferredTransform
        let presented = CGRect(x: 0, y: 0, width: width, height: height).applying(transform)
        return ["durationSeconds": seconds, "decodedFrames": count, "firstFrameSeconds": first,
                "validationBudgetSeconds": validationBudget,
                "validationElapsedSeconds": ProcessInfo.processInfo.systemUptime - validationStarted,
                "lastFrameSeconds": last, "width": width, "height": height, "bytes": bytes,
                "displayWidth": Int(presented.width.rounded()), "displayHeight": Int(presented.height.rounded()),
                "trackTransform": [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]]
    }
}
