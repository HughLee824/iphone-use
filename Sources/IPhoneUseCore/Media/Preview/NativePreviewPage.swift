import Foundation

private final class NativePreviewAssetAnchor: NSObject {}

// Artwork is loaded once, outside the video encoder. No network fetch, source
// path embedded in the binary, or dependency on the caller's working directory.
enum NativePreviewPage {
    // A symlink-launched CLI can have no executable URL on its class bundle.
    // Keep the class bundle for XCTest, then resolve the CLI's main entry point.
    static func assetDirectory(
        executable: URL? = Bundle(for: NativePreviewAssetAnchor.self).executableURL
            ?? Bundle.main.executableURL
    ) -> URL? {
        guard let executable else { return nil }
        let binary = executable.resolvingSymlinksInPath()
        let installed = binary.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("libexec/iphone-use/preview")
        if FileManager.default.fileExists(atPath: installed.appendingPathComponent("catalog.json").path) {
            return installed
        }
        var directory = binary.deletingLastPathComponent()
        // SwiftPM CLI and XCTest layouts have different depths under .build.
        for _ in 0..<8 {
            if directory.lastPathComponent == ".build" {
                return directory.deletingLastPathComponent().appendingPathComponent("assets/preview")
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    #if DEBUG
        static let appearanceComparisonEnabled = true
    #else
        static let appearanceComparisonEnabled = false
    #endif

    // Byte-for-byte copy of assets/brand/favicon-64.png, embedded for relocatable/offline previews.
    static let faviconPNG = Data(
        base64Encoded:
            """
            iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAACXBIWXMAACxLAAAsSwGlPZapAAADBUlEQVRoge2aMU/qUBT\
            H+Ral9A1icCCyaAuExMWJyRg/gYaErYsgkcUokjCU/RJGYTAhUpPOBJqYOOnAwNSFvZSWAIJK6EseyU3zfEItXMt99rdyzj/n\
            V24bSI9LxxyXjjkuHXNc+k8WkGW5UqlwHHdtCY7jKpVKp9OxQUCW5UQi4fF4iKXxeDzJZNKyhhUBSZIYhiFWCsMwkiR9h4Cma\
            aFQiEBAOBxWVRW5wMXFBYGMq6srtAIvLy8bGxsL5zg5OeF5XjDA8/zx8fHCRq/XOxqNEArU63UzF7LX633sVVXVTK8oiggFSq\
            WSmSFKpdJkMjE2TiaTm5sbM73lchmhAACAQAwAwBH4HOcbWAxwjtA8nCO0GOAcoXk4R+h/OUK//oCrAMuy4/F4NBqxLIulAPz\
            3KMsyfgKbm5swbTwe4ydA0zRM0zQNP4FoNArTJEnCTyAWi8E0URTxEygUCjCtWCziJ/D8/AzT8HuM+ny+9/d3mEbTNGYC5+fn\
            8+9gYs0FWq0WjMrlcpgJHB4ewpy3t7dAIICTgNvtfnp6gjmCIHxWCdZT4PT01JhzcHCAk0AgEJBlGYbc39/PKQbrJkBR1OPjI\
            0wYDoe7u7s4Cdze3hoTstns/HqwPgJut7tYLBrba7UaSZJ4CFAUVa1Wjb2SJG1tbS1sBOsgwDCM8dzrut7tdiORiJleYLtAMp\
            ns9/vGLk3TotGomekJGwVIkozH481m86+Wdru9t7dncnrCFgGSJFOpVLvd/ljfaDT8fr/56QlbBDiO+1g5GAysvc8E3y/w8PB\
            grJlOp4Ig7OzsWJiesEUgnU7PPn19feV5fn9/39rodt7ER0dHLMtub28TSwNsf4w6AsD+F93LUEb6otvkqsEyiEhXDUwue1jG\
            i3rZQ9f1y8tLdAKZTOar83xZQFXVcDiMYvpIJPLPNZcVC8x+2QeDwdVOHwqFvmnlbIaiKGdnZytZ+qMoKpVKdbtdG9YuFUW5u\
            7vL5/PW1i7z+Xy1WlUUZZkZfvbi6zrg0jHHZfcAy/Ib2Fmu6PHCFAAAAAAASUVORK5CYII=
            """
    )!

    static let html = [
        documentMarkup,
        setupScript,
        layoutScript,
        interactionScript,
        streamScript
    ].joined(separator: "\n")
}
