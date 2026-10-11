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
        let tail = Array(slice.suffix(14))
        // Recognized zero-origin rectangle with HEVC emulation prevention and
        // flags 0x03. Do not search backwards for a plausible pair of dimensions.
        guard Array(tail[4...8]) == [0, 0, 3, 0, 0], tail[13] == 3 else {
            throw Self.invalid("Unrecognized DisplayService frame metadata")
        }
        activeWidth = Int(tail[0]) << 8 | Int(tail[1])
        activeHeight = Int(tail[2]) << 8 | Int(tail[3])
        nativeWidth = Int(tail[9]) << 8 | Int(tail[10])
        nativeHeight = Int(tail[11]) << 8 | Int(tail[12])
        guard [activeWidth, activeHeight, nativeWidth, nativeHeight].allSatisfy({ (1...4096).contains($0) }),
              activeWidth % 16 == 0, activeHeight % 16 == 0 else {
            throw Self.invalid("Invalid DisplayService frame dimensions")
        }
    }

    func validate(canvas: CMVideoDimensions) throws {
        guard activeWidth <= Int(canvas.width), activeHeight <= Int(canvas.height),
              nativeWidth <= Int(canvas.width), nativeHeight <= Int(canvas.height),
              Int(canvas.width) - nativeWidth < 64, Int(canvas.height) - nativeHeight < 64 else {
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
