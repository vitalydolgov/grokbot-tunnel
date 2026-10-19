import Foundation

public struct ConfigPaths: Sendable {
    public let configDir: URL

    public init(configDir: URL) {
        self.configDir = configDir
    }

    public var credentialsURL: URL { configDir.appendingPathComponent(GrokBotTunnelConstants.credentialsFileName) }
    public var machineURL: URL { configDir.appendingPathComponent(GrokBotTunnelConstants.machineFileName) }
    public var stateURL: URL { configDir.appendingPathComponent(GrokBotTunnelConstants.stateFileName) }
    public var pidURL: URL { configDir.appendingPathComponent(GrokBotTunnelConstants.pidFileName) }

    public static func resolve(cliConfigDir: String? = nil) -> ConfigPaths {
        if let cli = cliConfigDir, !cli.isEmpty {
            return ConfigPaths(configDir: URL(fileURLWithPath: expandTilde(cli), isDirectory: true))
        }
        if let env = ProcessInfo.processInfo.environment["GROKBOT_TUNNEL_CONFIG_DIR"], !env.isEmpty {
            return ConfigPaths(configDir: URL(fileURLWithPath: expandTilde(env), isDirectory: true))
        }
        if let legacy = ProcessInfo.processInfo.environment["GROK_BOT_TUNNEL_CONFIG_DIR"], !legacy.isEmpty {
            return ConfigPaths(configDir: URL(fileURLWithPath: expandTilde(legacy), isDirectory: true))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(GrokBotTunnelConstants.defaultConfigDirName, isDirectory: true)
        return ConfigPaths(configDir: dir)
    }

    public static func expandTilde(_ path: String) -> String {
        if path == "~" { return FileManager.default.homeDirectoryForCurrentUser.path }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }

    public func ensureConfigDir() throws {
        try FileManager.default.createDirectory(
            at: configDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
