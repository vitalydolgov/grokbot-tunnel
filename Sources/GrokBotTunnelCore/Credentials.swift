import Foundation

public struct Credentials: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var selectedTeamId: String?
    public var savedAtMs: Int64?

    public init(
        accessToken: String,
        refreshToken: String,
        selectedTeamId: String? = nil,
        savedAtMs: Int64? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.selectedTeamId = selectedTeamId
        self.savedAtMs = savedAtMs
    }

    public var isValidShape: Bool {
        !accessToken.isEmpty && !refreshToken.isEmpty
    }
}

public struct MachineIdentity: Codable, Sendable, Equatable {
    public var machineId: String
    public var label: String

    public init(machineId: String, label: String) {
        self.machineId = machineId
        self.label = label
    }
}

public enum CredentialStore: Sendable {
    public static func load(from paths: ConfigPaths) throws -> Credentials? {
        let url = paths.credentialsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let creds = try JSONDecoder().decode(Credentials.self, from: data)
        guard creds.isValidShape else { return nil }
        return creds
    }

    public static func save(_ credentials: Credentials, to paths: ConfigPaths) throws {
        try paths.ensureConfigDir()
        var saved = credentials
        saved.savedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        let data = try JSONEncoder.pretty.encode(saved)
        try atomicWrite(data, to: paths.credentialsURL, mode: 0o600)
    }

    public static func delete(from paths: ConfigPaths) throws {
        let url = paths.credentialsURL
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public static func loadOrCreateMachine(
        paths: ConfigPaths,
        overrideMachineId: String? = nil,
        hostname: String = ProcessInfo.processInfo.hostName
    ) throws -> MachineIdentity {
        if let override = overrideMachineId, !override.isEmpty {
            let identity = MachineIdentity(machineId: override, label: hostname)
            try paths.ensureConfigDir()
            try atomicWrite(JSONEncoder.pretty.encode(identity), to: paths.machineURL, mode: 0o600)
            return identity
        }
        if FileManager.default.fileExists(atPath: paths.machineURL.path),
           let data = try? Data(contentsOf: paths.machineURL),
           let existing = try? JSONDecoder().decode(MachineIdentity.self, from: data),
           !existing.machineId.isEmpty
        {
            return existing
        }
        let created = MachineIdentity(machineId: UUID().uuidString.lowercased(), label: hostname)
        try paths.ensureConfigDir()
        try atomicWrite(JSONEncoder.pretty.encode(created), to: paths.machineURL, mode: 0o600)
        return created
    }
}

public enum JWTHelpers: Sendable {
    public static func payload(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - b64.count % 4) % 4
        b64 += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    public static func tokenExpiresSoon(
        _ accessToken: String,
        now: Date = Date(),
        margin: TimeInterval = GrokBotTunnelConstants.tokenRefreshMarginSeconds
    ) -> Bool {
        let exp = (payload(accessToken)["exp"] as? NSNumber)?.doubleValue
            ?? (payload(accessToken)["exp"] as? Double)
            ?? 0
        if exp == 0 { return true }
        return exp * 1000 - now.timeIntervalSince1970 * 1000 < margin * 1000
    }
}

enum FileIO {
    static func atomicWrite(_ data: Data, to url: URL, mode: Int) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700,
        ])
        let tmp = url.appendingPathExtension("\(ProcessInfo.processInfo.processIdentifier).tmp")
        try data.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}

func atomicWrite(_ data: Data, to url: URL, mode: Int) throws {
    try FileIO.atomicWrite(data, to: url, mode: mode)
}

extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
