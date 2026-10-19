import ArgumentParser
import Darwin
import Foundation
import GrokBotTunnelCore

struct Claim: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Attach reverse-tunnel with mode always claim (foreground until Ctrl-C / stop)."
    )

    @OptionGroup var shared: SharedOptions

    @Option(name: .long, help: "Tunnel WS URL or gateway HTTP(S) URL")
    var url: String?

    @Option(name: .long, help: "Gateway / tunnel bearer token")
    var token: String?

    @Flag(name: .long, help: "Do not call EnsureSandBox; require --url/--token or env")
    var noDiscover: Bool = false

    @Flag(name: .long, help: "Allow dialing private / loopback / link-local destinations")
    var allowPrivate: Bool = false

    func run() async throws {
        let paths = resolvePaths(shared.configDir)
        let identity = try CredentialStore.loadOrCreateMachine(
            paths: paths,
            overrideMachineId: shared.machineId
        )

        let resolvedURL = url
            ?? env("GROKBOT_TUNNEL_URL", "GROK_BOT_TUNNEL_URL")
        let resolvedToken = token
            ?? env("GROKBOT_TUNNEL_TOKEN", "GROK_BOT_TUNNEL_TOKEN")
        let allowPrivateEnv = env("GROKBOT_TUNNEL_ALLOW_PRIVATE", "GROK_BOT_TUNNEL_ALLOW_PRIVATE") == "1"
        let allowPrivateTargets = allowPrivate || allowPrivateEnv

        let tunnelURL: String
        let bearer: String
        var networkToken: String?

        if let resolvedURL, let resolvedToken {
            if resolvedURL.hasPrefix("ws") {
                tunnelURL = resolvedURL
            } else if let rewritten = GatewayRewrite.rewriteGatewayToTunnelWs(resolvedURL) {
                tunnelURL = rewritten
            } else {
                throw TunnelError.invalidURL(resolvedURL)
            }
            bearer = resolvedToken
        } else if noDiscover {
            throw TunnelError.missingURLAndToken
        } else {
            guard var credentials = try CredentialStore.load(from: paths) else {
                throw AuthError.notLoggedIn
            }
            let auth = AuthClient()
            credentials = try await auth.refreshIfNeeded(credentials, paths: paths)
            let box = try await auth.ensureSandBox(
                credentials: credentials,
                machineId: identity.machineId
            )
            guard let config = GatewayRewrite.tunnelConfigFromBox(
                gatewayUrl: box.gatewayUrl,
                gatewayToken: box.gatewayToken,
                networkToken: box.networkToken,
                vncUrl: box.vncUrl,
                forkVncBaseUrl: box.forkVncBaseUrl
            ) else {
                throw TunnelError.ensureSandBoxMissingGateway
            }
            tunnelURL = config.url
            bearer = config.bearer
            networkToken = config.networkToken
            if box.egressTunnelOwnership == true {
                FileHandle.standardError.write(Data(
                    "warning: box reports egressTunnelOwnership=true (another dialer may already hold the tunnel); claiming anyway.\n".utf8
                ))
            }
        }

        let clientId = TunnelClientId.make(machineId: identity.machineId)
        let options = ReverseTunnelOptions(
            url: tunnelURL,
            bearer: bearer,
            clientId: clientId,
            networkToken: networkToken,
            allowPrivateTargets: allowPrivateTargets,
            mode: GrokBotTunnelConstants.attachModeClaim
        )

        let client = ReverseTunnelClient(
            options: options,
            log: { msg in
                FileHandle.standardError.write(Data("\(msg)\n".utf8))
            },
            onStatus: { status in
                let state = DialerState(
                    state: status.state,
                    mode: status.mode,
                    confirmed: status.confirmed,
                    attachGen: status.attachGen,
                    relayedStreams: status.relayedStreams,
                    activeStreams: status.activeStreams,
                    lastError: status.lastError,
                    urlHost: URL(string: status.url)?.host,
                    machineId: identity.machineId,
                    label: identity.label,
                    pid: ProcessInfo.processInfo.processIdentifier
                )
                try? StateStore.save(state, to: paths)
            }
        )

        let signalSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let stopBox = StopBox(client: client, paths: paths)
        signalSource.setEventHandler { stopBox.stop(exitCode: 0) }
        intSource.setEventHandler { stopBox.stop(exitCode: 130) }
        signalSource.resume()
        intSource.resume()

        try StateStore.save(
            DialerState(
                state: "connecting",
                mode: GrokBotTunnelConstants.attachModeClaim,
                confirmed: false,
                machineId: identity.machineId,
                label: identity.label,
                pid: ProcessInfo.processInfo.processIdentifier
            ),
            to: paths
        )

        do {
            try await client.start()
            try await client.waitForConfirm(timeoutSeconds: 30)
        } catch {
            let failed = client.getStatus()
            try? StateStore.save(
                DialerState(
                    state: failed.state,
                    mode: failed.mode,
                    confirmed: false,
                    lastError: error.localizedDescription,
                    urlHost: URL(string: failed.url)?.host,
                    machineId: identity.machineId,
                    label: identity.label,
                    pid: ProcessInfo.processInfo.processIdentifier
                ),
                to: paths
            )
            throw error
        }

        let host = URL(string: tunnelURL)?.host ?? tunnelURL
        print("Reverse-tunnel dialer started (claim) for \(identity.label) (\(identity.machineId))")
        print("  WS peer host: \(host)")
        print("  Press Ctrl-C or run `grokbot-tunnel stop` to detach.")

        await client.runUntilStopped()
        StateStore.clear(from: paths)
    }
}

private final class StopBox: @unchecked Sendable {
    private let client: ReverseTunnelClient
    private let paths: ConfigPaths
    private let lock = NSLock()
    private var stopped = false

    init(client: ReverseTunnelClient, paths: ConfigPaths) {
        self.client = client
        self.paths = paths
    }

    func stop(exitCode: Int32) {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        client.stop()
        StateStore.clear(from: paths)
        Foundation.exit(exitCode)
    }
}
