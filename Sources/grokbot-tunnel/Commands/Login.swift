import ArgumentParser
import Foundation
import GrokBotTunnelCore

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "PKCE browser login (poll /auth/poll) and save credentials (0600)."
    )

    @OptionGroup var shared: SharedOptions

    func run() async throws {
        let paths = resolvePaths(shared.configDir)
        let auth = AuthClient()
        let session = try auth.beginLogin()
        print("Open this URL in any browser and complete sign-in:\n")
        print(session.loginURL.absoluteString)
        print("\nWaiting for authorization...")
        let credentials = try await auth.pollForTokens(pollURL: session.pollURL)
        try CredentialStore.save(credentials, to: paths)
        _ = try CredentialStore.loadOrCreateMachine(paths: paths, overrideMachineId: shared.machineId)
        let host = ProcessInfo.processInfo.hostName
        print("Account authorized for \(host).")
    }
}
