import Foundation
import CryptoKit
import ImageIO

struct NativePreviewDevice {
    let productType: String?
    let name: String?

    static let unknown = NativePreviewDevice(productType: nil, name: nil)

    init(productType: String?, name: String?) {
        self.productType = productType; self.name = name
    }

    init(details: [String: Any]) {
        let hardware = details["hardwareProperties"] as? [String: Any] ?? [:]
        productType = hardware["productType"] as? String
        name = hardware["marketingName"] as? String
    }

    var facts: [String: Any] {
        ["productType": productType as Any? ?? NSNull(), "name": name as Any? ?? NSNull()]
    }
}

struct NativePreviewBezel {
    struct Profile: Codable {
        let name: String
        let file: String
        let sha256: String
        let canvasWidth: Double
        let canvasHeight: Double
        let screenX: Double
        let screenY: Double
        let screenWidth: Double
        let screenHeight: Double
        let cornerRadius: Double

        var valid: Bool {
            let values = [
                canvasWidth, canvasHeight, screenX, screenY, screenWidth, screenHeight, cornerRadius
            ]
            return values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 16384 }
                && canvasWidth > 0 && canvasHeight > 0 && screenWidth > 0 && screenHeight > 0
                && screenX + screenWidth <= canvasWidth && screenY + screenHeight <= canvasHeight
                && cornerRadius <= min(screenWidth, screenHeight) / 2
                && file.range(of: "^[a-z0-9-]+[.]png$", options: .regularExpression) != nil
                && sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
        }

        var facts: [String: Any] {
            [
                "name": name, "canvasWidth": canvasWidth, "canvasHeight": canvasHeight,
                "screenX": screenX, "screenY": screenY, "screenWidth": screenWidth,
                "screenHeight": screenHeight, "cornerRadius": cornerRadius
            ]
        }
    }

    struct Catalog: Decodable {
        let version: Int
        let models: [String: Profile]
    }

    let profile: Profile
    let png: Data

    static func load(device: NativePreviewDevice, directory: URL? = NativePreviewPage.assetDirectory())
        -> NativePreviewBezel? {
        // Model identity is the only selector. Geometry below is validation,
        // never a fallback selector for a different phone with a similar screen.
        guard let productType = device.productType, let directory,
            let bytes = try? Data(contentsOf: directory.appendingPathComponent("catalog.json")),
            let catalog = try? JSONDecoder().decode(Catalog.self, from: bytes), catalog.version == 1,
            let profile = catalog.models[productType], profile.valid,
            let png = try? Data(contentsOf: directory.appendingPathComponent(profile.file)),
            SHA256.hash(data: png).map({ String(format: "%02x", $0) }).joined() == profile.sha256,
            let image = CGImageSourceCreateWithData(png as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any],
            (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.doubleValue
                == profile.canvasWidth,
            (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.doubleValue
                == profile.canvasHeight
        else { return nil }
        return NativePreviewBezel(profile: profile, png: png)
    }
}
