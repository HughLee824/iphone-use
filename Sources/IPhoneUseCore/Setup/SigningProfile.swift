import Foundation
import CryptoKit

struct SigningProfile {
    let url: URL
    let data: Data
    let identifier: String
    let name: String
    let team: String
    let prefix: String
    let applicationIdentifier: String
    let expires: Date
    let devices: [String]
    let identities: Set<String>

    init(url: URL) throws {
        let content = try SigningTool.require(
            "/usr/bin/security", ["cms", "-D", "-i", url.path], code: "profile_unreadable")
        guard
            let plist = try PropertyListSerialization.propertyList(from: content, format: nil)
                as? [String: Any]
        else {
            throw IPhoneUseError("profile_invalid", "Provisioning profile is not a property list")
        }
        try self.init(url: url, data: Data(contentsOf: url), plist: plist)
    }

    init(url: URL, data: Data, plist: [String: Any]) throws {
        guard let identifier = plist["UUID"] as? String,
            let name = plist["Name"] as? String,
            let team = (plist["TeamIdentifier"] as? [String])?.first,
            let prefix = (plist["ApplicationIdentifierPrefix"] as? [String])?.first,
            let expires = plist["ExpirationDate"] as? Date,
            let devices = plist["ProvisionedDevices"] as? [String],
            let entitlements = plist["Entitlements"] as? [String: Any],
            entitlements["get-task-allow"] as? Bool == true,
            entitlements["com.apple.developer.team-identifier"] as? String == team,
            let applicationIdentifier = entitlements["application-identifier"] as? String,
            let certificates = plist["DeveloperCertificates"] as? [Data], !certificates.isEmpty,
            (plist["Platform"] as? [String])?.contains("iOS") == true
        else {
            throw IPhoneUseError(
                "profile_invalid",
                "Use an iOS development provisioning profile with device registration and get-task-allow")
        }
        self.url = url; self.data = data; self.identifier = identifier; self.name = name
        self.team = team; self.prefix = prefix; self.expires = expires; self.devices = devices
        self.applicationIdentifier = applicationIdentifier
        identities = Set(
            certificates.map { Insecure.SHA1.hash(data: $0).map { String(format: "%02X", $0) }.joined() })
    }

    func validate(device: String, bundleID: String, identity: String? = nil, now: Date = Date()) throws {
        guard expires > now else {
            throw IPhoneUseError(
                "profile_expired", "Provisioning profile expired; renew it in Xcode, then run setup again")
        }
        guard devices.contains(device) else {
            throw IPhoneUseError(
                "profile_device_mismatch", "Provisioning profile does not include the selected iPhone")
        }
        let requested = prefix + "." + bundleID
        let matches =
            applicationIdentifier.hasSuffix("*")
            ? requested.hasPrefix(String(applicationIdentifier.dropLast()))
            : requested == applicationIdentifier
        guard matches else {
            throw IPhoneUseError(
                "profile_bundle_mismatch",
                """
                Provisioning profile does not authorize Runner bundle ID \(bundleID); select its profile or\
                 pass --bundle-id
                """
            )
        }
        if let identity, !identities.contains(identity) {
            throw IPhoneUseError(
                "profile_identity_mismatch",
                "Selected signing identity is not included in this provisioning profile")
        }
    }

    func entitlements(bundleID: String) -> [String: Any] {
        [
            "application-identifier": prefix + "." + bundleID, "com.apple.developer.team-identifier": team,
            "get-task-allow": true, "keychain-access-groups": [prefix + "." + bundleID]
        ]
    }

    static func visibleIdentities() throws -> Set<String> {
        let output = try SigningTool.require(
            "/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"],
            code: "signing_identity_unavailable")
        return try parseIdentities(SigningTool.decodeOutput(output))
    }

    static func parseIdentities(_ text: String) throws -> Set<String> {
        let pattern = try NSRegularExpression(
            pattern: #"\b([A-Fa-f0-9]{40})\s+\"(?:Apple Development|iPhone Developer):"#)
        return Set(
            pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]).uppercased() }
            })
    }

    static func select(
        device: String, bundleID: String, profileURL: URL?, identity: String?, team: String?,
        savedProfileURL: URL? = nil, preferredIdentity: String? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> (SigningProfile, String) {
        let visible = try visibleIdentities()
        guard !visible.isEmpty else {
            throw IPhoneUseError(
                "signing_identity_unavailable",
                """
                No usable Apple Development identity is visible in this execution context. Configure signing\
                 in Xcode or use approved host permissions, then retry setup
                """
            )
        }
        let identity = identity?.uppercased()
        if let identity, !visible.contains(identity) {
            throw IPhoneUseError(
                "signing_identity_unavailable",
                "--identity must name an available Apple Development certificate SHA-1")
        }
        if let profileURL {
            let profile = try SigningProfile(url: profileURL)
            try profile.validate(device: device, bundleID: bundleID, identity: identity)
            if let team, profile.team != team {
                throw IPhoneUseError(
                    "profile_team_mismatch", "Provisioning profile does not belong to --team")
            }
            return try selectIdentity(
                profile, visible: visible, identity: identity, preferredIdentity: preferredIdentity)
        }
        var matches: [(SigningProfile, String)] = []
        var urls = savedProfileURL.map { [$0] } ?? []
        for path in [
            "Library/Developer/Xcode/UserData/Provisioning Profiles",
            "Library/MobileDevice/Provisioning Profiles"
        ] {
            urls +=
                (try? FileManager.default.contentsOfDirectory(
                    at: home.appendingPathComponent(path), includingPropertiesForKeys: nil)) ?? []
        }
        for url in Set(urls) where url.pathExtension == "mobileprovision" {
            guard let profile = try? SigningProfile(url: url), team == nil || profile.team == team,
                (try? profile.validate(device: device, bundleID: bundleID, identity: identity)) != nil
            else { continue }
            for candidate in profile.identities.intersection(visible)
            where identity == nil || candidate == identity {
                matches.append((profile, candidate))
            }
        }
        return try choose(matches, bundleID: bundleID, preferredIdentity: preferredIdentity)
    }

    private static func selectIdentity(
        _ profile: SigningProfile, visible: Set<String>, identity: String?,
        preferredIdentity: String?
    ) throws -> (SigningProfile, String) {
        let candidates = profile.identities.intersection(visible).filter { identity == nil || $0 == identity }
        guard !candidates.isEmpty else {
            throw IPhoneUseError(
                "signing_identity_unavailable",
                """
                This profile has no matching Apple Development private key visible in the current\
                 execution context; select a renewed --profile or check Keychain access
                """
            )
        }
        if let preferredIdentity, candidates.contains(preferredIdentity) {
            return (profile, preferredIdentity)
        }
        guard candidates.count == 1, let match = candidates.first else {
            throw IPhoneUseError(
                "signing_identity_ambiguous",
                """
                Select a matching certificate using --identity; available matches:\
                 \(candidates.sorted().joined(separator: ", "))
                """
            )
        }
        return (profile, match)
    }

    static func choose(_ candidates: [(SigningProfile, String)], bundleID: String, preferredIdentity: String?)
        throws
        -> (SigningProfile, String) {
        var matches = candidates
        if let preferredIdentity, matches.contains(where: { $0.1 == preferredIdentity }) {
            matches = matches.filter { $0.1 == preferredIdentity }
        }
        // A renewed copy of the same signing configuration may coexist with the old one.
        let configurations = Set(matches.map { $0.0.team + ":" + $0.1 })
        guard !matches.isEmpty else {
            throw IPhoneUseError(
                "profile_not_found",
                """
                No visible iOS development profile authorizes this device and \(bundleID). Configure\
                 provisioning in Xcode or pass --profile; setup only re-signs the precompiled Runner
                """
            )
        }
        guard configurations.count == 1 else {
            throw IPhoneUseError(
                "signing_identity_ambiguous",
                "Multiple signing configurations match; select --team, --identity or --profile")
        }
        return matches.sorted { left, right in
            left.0.expires == right.0.expires
                ? left.0.identifier < right.0.identifier : left.0.expires > right.0.expires
        }[0]
    }
}
