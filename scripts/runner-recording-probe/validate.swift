import Foundation
import AVFoundation
import AppKit

// Compile with the production NativeRecordingValidation.swift so this probe
// uses exactly the same full-decode validation as standard-mode recordings.
struct IPhoneUseError: Error {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
}

let video = URL(fileURLWithPath: CommandLine.arguments[1])
var facts = try NativeRecordingValidation.inspect(video)
let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
generator.appliesPreferredTrackTransform = true
let frame = try generator.copyCGImage(at: CMTime(value: 1, timescale: 1), actualTime: nil)
guard let png = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]) else {
    throw IPhoneUseError("preview_failed", "Could not encode the decoded preview")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
facts["fileValidated"] = true
print(String(decoding: try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]), as: UTF8.self))
