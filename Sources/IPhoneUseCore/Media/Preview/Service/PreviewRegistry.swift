import Foundation

// Serialized by PreviewService.queue. Only credentials persist; sources and leases never do.
final class PreviewRegistry {
    struct Source: Equatable {
        let owner: String
        let url: String
        var deadline: Double
    }
    struct Entry: Codable {
        let device: String
        var token: String
    }
    private let directory: URL
    private var entries: [Entry]
    private var sources: [String: Source] = [:]
    private var idleGenerations: [String: String] = [:]
    let authorization: String

    init(directory: URL) throws {
        try SessionPaths.secureDirectory(directory)
        self.directory = directory
        let credentials = directory.appendingPathComponent("authorization")
        if FileManager.default.fileExists(atPath: credentials.path) {
            authorization = String(data: try Self.readPrivate(credentials), encoding: .utf8) ?? ""
            guard UUID(uuidString: authorization) != nil else {
                throw IPhoneUseError("invalid_preview_store", "Invalid preview service credential")
            }
        } else {
            authorization = UUID().uuidString
            try Self.writePrivate(Data(authorization.utf8), to: credentials)
        }
        let file = directory.appendingPathComponent("entries.json")
        entries = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder().decode([Entry].self, from: Self.readPrivate(file)) : []
        guard Set(entries.map(\.device)).count == entries.count,
            Set(entries.map(\.token)).count == entries.count,
            entries.allSatisfy({ UUID(uuidString: $0.token) != nil && Self.validDevice($0.device) })
        else { throw IPhoneUseError("invalid_preview_store", "Invalid device preview entries") }
    }

    static func readPrivate(_ file: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
            (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 65536
        else { throw IPhoneUseError("unsafe_preview_store", "Preview credentials require owned 0600 files") }
        return try Data(contentsOf: file)
    }

    static func writePrivate(_ data: Data, to file: URL) throws {
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func validDevice(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9-]{1,128}$", options: .regularExpression) != nil
    }

    func entry(device: String) throws -> Entry {
        guard Self.validDevice(device) else {
            throw IPhoneUseError("invalid_device_id", "Use the exact hardware UDID")
        }
        if let entry = entries.first(where: { $0.device == device }) { return entry }
        let entry = Entry(device: device, token: UUID().uuidString)
        let next = entries + [entry]
        try persist(next); entries = next
        return entry
    }

    func entry(token: String) -> Entry? { entries.first { $0.token == token } }

    func attach(device: String, owner: String, url: String, now: Double) throws -> Entry {
        guard let parsed = URL(string: url), parsed.scheme == "http", parsed.host == "127.0.0.1",
            parsed.port != nil, parsed.user == nil, parsed.password == nil,
            parsed.query == nil, parsed.fragment == nil,
            parsed.path.split(separator: "/").count == 1,
            UUID(uuidString: parsed.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) != nil,
            UUID(uuidString: owner) != nil
        else { throw IPhoneUseError("invalid_preview_source", "Expected an owned loopback preview source") }
        let entry = try entry(device: device)
        if let existing = source(device: device, now: now), existing.owner != owner || existing.url != url {
            throw IPhoneUseError("preview_owner_busy", "The device preview still has an active owner")
        }
        sources[device] = Source(owner: owner, url: url, deadline: now + 6)
        return entry
    }

    func source(device: String, now: Double) -> Source? {
        if let source = sources[device], source.deadline <= now {
            detach(device: device, owner: source.owner)
        }
        return sources[device]
    }

    func renew(device: String, owner: String, now: Double) throws {
        guard var source = source(device: device, now: now), source.owner == owner else {
            throw IPhoneUseError(
                "preview_binding_lost", "Preview stopped, expired or revoked; explicitly restart preview")
        }
        source.deadline = now + 6; sources[device] = source
    }

    func detach(device: String, owner: String) {
        guard sources[device]?.owner == owner else { return }
        sources.removeValue(forKey: device); idleGenerations[device] = UUID().uuidString
    }

    func idleGeneration(device: String) -> String {
        if let value = idleGenerations[device] { return value }
        let value = UUID().uuidString; idleGenerations[device] = value; return value
    }

    func revoke(device: String) throws {
        let entry = try entry(device: device)
        let next = entries.map { $0.device == device ? Entry(device: device, token: UUID().uuidString) : $0 }
        try persist(next); entries = next
        if let source = sources[entry.device] { detach(device: entry.device, owner: source.owner) }
    }

    private func persist(_ entries: [Entry]) throws {
        try Self.writePrivate(try JSONEncoder().encode(entries), to: directory.appendingPathComponent("entries.json"))
    }
}
