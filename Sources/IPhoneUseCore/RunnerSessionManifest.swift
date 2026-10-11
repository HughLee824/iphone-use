import Foundation

enum RunnerSessionManifest {
    // Keep the caller's signed products/manifest untouched. Automatic XCTest
    // diagnostics use screenshots; explicit recording belongs to native media.
    static func prepare(source: URL, destination: URL) throws {
        guard let original = try PropertyListSerialization.propertyList(from: Data(contentsOf: source), format: nil) as? [String: Any] else {
            throw IPhoneUseError("runner_manifest_invalid", "Expected an XCTest manifest dictionary")
        }
        func relocate(_ value: Any) -> Any {
            if let string = value as? String { return string.replacingOccurrences(of: "__TESTROOT__", with: source.deletingLastPathComponent().path) }
            if let array = value as? [Any] { return array.map(relocate) }
            if let dictionary = value as? [String: Any] { return dictionary.mapValues(relocate) }
            return value
        }
        var manifest = relocate(original) as! [String: Any]
        var found = false
        if var target = manifest["IPhoneUseTests"] as? [String: Any] {
            target["PreferredScreenCaptureFormat"] = "screenshots"
            manifest["IPhoneUseTests"] = target; found = true
        }
        if var configurations = manifest["TestConfigurations"] as? [[String: Any]] {
            for index in configurations.indices {
                var targets = configurations[index]["TestTargets"] as? [[String: Any]] ?? []
                for target in targets.indices where targets[target]["BlueprintName"] as? String == "IPhoneUseTests" {
                    targets[target]["PreferredScreenCaptureFormat"] = "screenshots"; found = true
                }
                configurations[index]["TestTargets"] = targets
            }
            manifest["TestConfigurations"] = configurations
        }
        guard found else { throw IPhoneUseError("runner_manifest_invalid", "No IPhoneUseTests target in XCTest manifest") }
        try PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: 0).write(to: destination, options: .atomic)
    }
}
