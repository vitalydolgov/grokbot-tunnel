import ArgumentParser
import Darwin
import Foundation
import GrokBotTunnelCore

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "SIGTERM the dialer process started by claim."
    )

    @OptionGroup var shared: SharedOptions

    func run() async throws {
        let paths = resolvePaths(shared.configDir)
        if let pid = StateStore.readPid(from: paths), StateStore.processAlive(pid) {
            let rc = kill(pid, SIGTERM)
            if rc != 0 {
                throw ExitCode(1)
            }
            print("Sent SIGTERM to reverse-tunnel pid \(pid).")
            return
        }
        StateStore.clear(from: paths)
        print("No running reverse-tunnel process; cleared state file if present.")
    }
}
