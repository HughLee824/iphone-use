import Foundation

struct HostConfiguration: Codable {
    let session: String
    let device: String
    let xctestrun: String
    let idleTimeoutSeconds: TimeInterval
    var backend: String?
    var nativeEndpointInventory: String?
    var modeSource: String?
    var startupPreviewPort: Int?

    var modeSelection: ModeSelection {
        ModeSelection(
            mode: backend == "apple-native" ? .standard : .runner,
            source: modeSource ?? "legacy_session")
    }
}
