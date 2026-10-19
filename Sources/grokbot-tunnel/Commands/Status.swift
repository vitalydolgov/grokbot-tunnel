import ArgumentParser
import Darwin
import Foundation
import GrokBotTunnelCore

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "JSON account + dialer status (never prints tokens/secrets)."
    )

    @OptionGroup var shared: SharedOptions

    func run() async throws {
        let paths = resolvePaths(shared.configDir)
        let credentials = try CredentialStore.load(from: paths)
        let identity: MachineIdentity? = {
            if let override = shared.machineId, !override.isEmpty {
                return MachineIdentity(machineId: override, label: ProcessInfo.processInfo.hostName)
            }
            return CredentialStore.loadMachine(from: paths)
        }()
        let dialer = StateStore.load(from: paths)
        let pid = dialer?.pid ?? StateStore.readPid(from: paths)
        let alive = pid.map(StateStore.processAlive) ?? false

        var dialerJSON: [String: Any] = [
            "running": alive,
            "state": alive ? (dialer?.state ?? "unknown") : "off",
        ]
        if let dialer {
            if let mode = dialer.mode { dialerJSON["mode"] = mode }
            if let confirmed = dialer.confirmed { dialerJSON["confirmed"] = confirmed }
            if let attachGen = dialer.attachGen { dialerJSON["attachGen"] = attachGen }
            if let n = dialer.relayedStreams { dialerJSON["relayedStreams"] = n }
            if let n = dialer.activeStreams { dialerJSON["activeStreams"] = n }
            if let err = dialer.lastError { dialerJSON["lastError"] = err }
            if let host = dialer.urlHost { dialerJSON["urlHost"] = host }
            if let updated = dialer.updatedAtMs { dialerJSON["updatedAtMs"] = updated }
        }
        if let pid { dialerJSON["pid"] = pid }
        dialerJSON["pidAlive"] = alive

        var out: [String: Any] = [
            "account": accountStatusJSON(credentials: credentials),
            "dialer": dialerJSON,
            "configDir": paths.configDir.path,
        ]
        if let identity {
            out["machine"] = [
                "machineId": identity.machineId,
                "label": identity.label,
                "tunnelClientId": TunnelClientId.make(machineId: identity.machineId),
            ]
        }
        try printJSON(out)
    }
}
