import Foundation
import CoreGraphics
import ImageIO
import AppleNativeBridge

enum NativeEndpointInventory {
    static func read(path: String?, now: Date = Date()) throws -> String? {
        guard let path else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            let modified = attributes[.modificationDate] as? Date,
            (0...30).contains(now.timeIntervalSince(modified)),
            let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 16 * 1024 * 1024
        else {
            throw IPhoneUseError(
                "native_endpoint_inventory_invalid",
                "Provide a nonempty, regular Apple netstat -anvl -p tcp output file captured within 30 seconds"
            )
        }
        return try String(contentsOfFile: path, encoding: .utf8)
    }
}
