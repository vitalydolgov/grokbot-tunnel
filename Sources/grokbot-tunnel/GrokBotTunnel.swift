import ArgumentParser
import Foundation
import GrokBotTunnelCore

@main
struct GrokBotTunnel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grokbot-tunnel",
        abstract: "Cursor/Grok Bot OAuth login and reverse-tunnel claim dialer.",
        subcommands: [Login.self, Logout.self, Status.self, Claim.self, Stop.self],
        defaultSubcommand: nil
    )
}

struct SharedOptions: ParsableArguments {
    @Option(name: .long, help: "Config directory (default: ~/.config/grokbot-tunnel)")
    var configDir: String?

    @Option(name: .long, help: "Override machine id used for tunnel client id / checksum")
    var machineId: String?
}

func resolvePaths(_ configDir: String?) -> ConfigPaths {
    ConfigPaths.resolve(cliConfigDir: configDir)
}

func env(_ keys: String...) -> String? {
    let env = ProcessInfo.processInfo.environment
    for key in keys {
        if let v = env[key], !v.isEmpty { return v }
    }
    return nil
}

func printJSON(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    if let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

func accountStatusJSON(credentials: Credentials?) -> [String: Any] {
    guard let credentials else {
        return ["loggedIn": false]
    }
    let payload = JWTHelpers.payload(credentials.accessToken)
    var account: [String: Any] = [
        "loggedIn": true,
        "hasRefreshToken": !credentials.refreshToken.isEmpty,
    ]
    if let sub = payload["sub"] as? String {
        account["subject"] = sub
    }
    if let exp = payload["exp"] {
        account["accessTokenExp"] = exp
    }
    if let team = credentials.selectedTeamId {
        account["selectedTeamId"] = team
    }
    // Never include tokens/secrets.
    return account
}
