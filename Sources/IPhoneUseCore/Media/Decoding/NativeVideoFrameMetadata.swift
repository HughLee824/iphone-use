import Foundation
import CoreMedia

// Narrow DisplayService profile verified on macOS/iOS 27. These bytes are
// Apple metadata, not a generic HEVC footer. Unknown layouts fail closed.
struct NativeVideoFrameMetadata: Equatable {
    let activeWidth: Int
    let activeHeight: Int
    let nativeWidth: Int
    let nativeHeight: Int

    init(nals: [Data]) throws {
        let slices = nals.filter { $0.count >= 2 && ($0[$0.startIndex] >> 1) & 63 <= 31 }
        guard slices.count == 1, let slice = slices.first, slice.count >= 16 else {
            throw Self.invalid("Expected one complete DisplayService slice")
        }
        // The rectangle is 13 RBSP bytes, not a fixed 14 EBSP bytes. For
        // example activeHeight=1280 ends in 0x00 and causes a SECOND 0x03
        // emulation-prevention byte across the following zero-origin field.
        // Decode a bounded suffix then read the fixed trailing layout; never
        // search backwards for a plausible rectangle or accept another flags value.
        let encoded = Array(slice.suffix(32))
        var decoded: [UInt8] = [], zeros = 0
        for index in encoded.indices {
            let byte = encoded[index]
            if zeros == 2 && byte == 3 {
                guard index + 1 < encoded.count, encoded[index + 1] <= 3 else {
                    throw Self.invalid("Invalid HEVC emulation-prevention byte")
                }
                zeros = 0; continue
            }
            guard zeros != 2 || byte > 2 else {
                throw Self.invalid("Missing HEVC emulation-prevention byte")
            }
            decoded.append(byte)
            zeros = byte == 0 ? min(2, zeros + 1) : 0
        }
        guard decoded.count >= 13 else { throw Self.invalid("Truncated DisplayService frame metadata") }
        let tail = Array(decoded.suffix(13))
        guard Array(tail[4...7]) == [0, 0, 0, 0], tail[12] == 3 else {
            throw Self.invalid("Unrecognized DisplayService frame metadata")
        }
        activeWidth = Int(tail[0]) << 8 | Int(tail[1])
        activeHeight = Int(tail[2]) << 8 | Int(tail[3])
        nativeWidth = Int(tail[8]) << 8 | Int(tail[9])
        nativeHeight = Int(tail[10]) << 8 | Int(tail[11])
        guard [activeWidth, activeHeight, nativeWidth, nativeHeight].allSatisfy({ (1...4096).contains($0) }),
            activeWidth % 16 == 0, activeHeight % 16 == 0
        else {
            throw Self.invalid("Invalid DisplayService frame dimensions")
        }
    }

    func validate(canvas: CMVideoDimensions) throws {
        guard activeWidth <= Int(canvas.width), activeHeight <= Int(canvas.height),
            nativeWidth <= Int(canvas.width), nativeHeight <= Int(canvas.height),
            Int(canvas.width) - nativeWidth < 64, Int(canvas.height) - nativeHeight < 64
        else {
            throw Self.invalid("Frame metadata disagrees with the HEVC canvas")
        }
    }

    func hasFullResolution(canvas: CMVideoDimensions) -> Bool {
        activeWidth == Int(canvas.width) && activeHeight == Int(canvas.height)
    }

    private static func invalid(_ message: String) -> IPhoneUseError {
        IPhoneUseError("native_video_metadata_invalid", message)
    }
}
