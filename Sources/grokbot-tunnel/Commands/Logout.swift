import ArgumentParser
import Darwin
import Foundation
import GrokBotTunnelCore

struct Logout: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete saved credentials; stop dialer if this tool owns it."
    )

    @OptionGroup var shared: SharedOptions

    func run() async throws {
        let paths = resolvePaths(shared.configDir)
        if let pid = StateStore.readPid(from: paths), StateStore.processAlive(pid) {
            kill(pid, SIGTERM)
            print("Sent SIGTERM to reverse-tunnel pid \(pid).")
        }
        StateStore.clear(from: paths)
        try CredentialStore.delete(from: paths)
        print("Credentials removed.")
    }
}
