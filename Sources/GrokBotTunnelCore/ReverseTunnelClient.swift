import Foundation
import Network

public struct ReverseTunnelStatus: Sendable, Equatable {
    public var state: String
    public var mode: String
    public var confirmed: Bool
    public var attachGen: String?
    public var relayedStreams: Int
    public var activeStreams: Int
    public var lastError: String?
    public var url: String

    public init(
        state: String,
        mode: String,
        confirmed: Bool,
        attachGen: String? = nil,
        relayedStreams: Int = 0,
        activeStreams: Int = 0,
        lastError: String? = nil,
        url: String
    ) {
        self.state = state
        self.mode = mode
        self.confirmed = confirmed
        self.attachGen = attachGen
        self.relayedStreams = relayedStreams
        self.activeStreams = activeStreams
        self.lastError = lastError
        self.url = url
    }
}

public struct ReverseTunnelOptions: Sendable {
    public var url: String
    public var bearer: String
    public var clientId: String
    public var networkToken: String?
    public var allowPrivateTargets: Bool
    public var mode: String

    public init(
        url: String,
        bearer: String,
        clientId: String,
        networkToken: String? = nil,
        allowPrivateTargets: Bool = false,
        mode: String = GrokBotTunnelConstants.attachModeClaim
    ) {
        self.url = url
        self.bearer = bearer
        self.clientId = clientId
        self.networkToken = networkToken
        self.allowPrivateTargets = allowPrivateTargets
        self.mode = mode
    }
}

public actor ReverseTunnelClient {
    private let options: ReverseTunnelOptions
    private let log: @Sendable (String) -> Void
    private let onStatus: @Sendable (ReverseTunnelStatus) -> Void

    private var state = "off"
    private var confirmed = false
    private var attachGen: String?
    private var lastError: String?
    private var relayedStreams = 0
    private var stopping = false

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var receiveLoopTask: Task<Void, Never>?
    private var streams: [UInt32: StreamEntry] = [:]

    private final class StreamEntry: @unchecked Sendable {
        var connection: NWConnection?
        var pending: [Data] = []
        var closedByPeer = false
    }

    public init(
        options: ReverseTunnelOptions,
        log: @escaping @Sendable (String) -> Void = { _ in },
        onStatus: @escaping @Sendable (ReverseTunnelStatus) -> Void = { _ in }
    ) {
        self.options = options
        self.log = log
        self.onStatus = onStatus
    }

    public func getStatus() -> ReverseTunnelStatus {
        ReverseTunnelStatus(
            state: state,
            mode: options.mode,
            confirmed: confirmed,
            attachGen: attachGen,
            relayedStreams: relayedStreams,
            activeStreams: streams.count,
            lastError: lastError,
            url: options.url
        )
    }

    private func setState(_ newState: String) {
        state = newState
        let status = getStatus()
        onStatus(status)
    }

    public func start() async throws {
        if webSocketTask != nil {
            throw TunnelError.alreadyStarted
        }
        stopping = false
        confirmed = false
        attachGen = nil
        lastError = nil
        setState("connecting")

        guard let url = URL(string: options.url) else {
            throw TunnelError.invalidURL(options.url)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(options.bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(options.mode, forHTTPHeaderField: GrokBotTunnelConstants.headerAttach)
        request.setValue(options.clientId, forHTTPHeaderField: GrokBotTunnelConstants.headerClient)
        if let token = options.networkToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: GrokBotTunnelConstants.headerNetworkToken)
        }

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.webSocketTask = task
        task.resume()

        setState("connected")
        log("reverse-tunnel: attached to \(safeHost(options.url)); waiting for the box to answer")

        receiveLoopTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            }
            markConfirmed()
        } catch {
            // Ping failure is non-fatal; confirmation may still arrive via frames.
            log("reverse-tunnel: initial ping failed: \(error.localizedDescription)")
        }
    }

    public func waitForConfirm(timeoutSeconds: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if confirmed { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if !confirmed {
            throw TunnelError.confirmTimeout
        }
    }

    public func runUntilStopped() async {
        while !stopping && webSocketTask != nil {
            try? await Task.sleep(nanoseconds: 500_000_000)
            onStatus(getStatus())
        }
    }

    public func stop() {
        stopping = true
        let task = webSocketTask
        webSocketTask = nil
        let session = self.session
        self.session = nil
        let entries = streams
        streams.removeAll()
        confirmed = false

        receiveLoopTask?.cancel()
        receiveLoopTask = nil

        for (_, entry) in entries {
            entry.connection?.cancel()
        }
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        setState("off")
    }

    private func markConfirmed() {
        guard !confirmed else { return }
        confirmed = true
        log("reverse-tunnel: the box confirmed the \(options.mode) attach")
        onStatus(getStatus())
    }

    private func receiveLoop() async {
        while true {
            guard let task = webSocketTask, !stopping else { return }
            do {
                let message = try await task.receive()
                markConfirmed()
                switch message {
                case .data(let data):
                    await handleFrame(data)
                case .string:
                    break
                @unknown default:
                    break
                }
            } catch {
                if lastError == nil {
                    lastError = error.localizedDescription
                }
                let isStopping = stopping
                webSocketTask = nil
                if !isStopping {
                    log("reverse-tunnel: socket closed: \(error.localizedDescription)")
                    setState("off")
                }
                for (_, entry) in streams {
                    entry.connection?.cancel()
                }
                streams.removeAll()
                return
            }
        }
    }

    private func handleFrame(_ raw: Data) async {
        guard let frame = FrameCodec.decode(raw) else { return }
        switch frame {
        case .open(let streamId, let host, let port):
            await openStream(streamId: streamId, host: host, port: port)
        case .data(let streamId, let payload):
            guard let entry = streams[streamId] else { return }
            if let connection = entry.connection {
                connection.send(content: payload, completion: .contentProcessed { _ in })
            } else {
                entry.pending.append(payload)
            }
        case .close(let streamId):
            guard let entry = streams[streamId] else { return }
            if let connection = entry.connection {
                streams.removeValue(forKey: streamId)
                connection.cancel()
            } else {
                entry.closedByPeer = true
            }
        }
    }

    private func openStream(streamId: UInt32, host: String, port: UInt16) async {
        if streams[streamId] != nil {
            send(FrameCodec.encodeClose(streamId: streamId))
            return
        }
        let entry = StreamEntry()
        streams[streamId] = entry

        let address: String?
        if PrivateIPGate.parseIPv4(host) != nil || host.contains(":") {
            if options.allowPrivateTargets || !PrivateIPGate.isBlockedDestinationIP(host) {
                address = host
            } else {
                address = nil
            }
        } else {
            address = await Self.resolveHost(host, allowPrivate: options.allowPrivateTargets)
        }

        let stillOurs = streams[streamId] === entry
        guard let address, stillOurs, !stopping, webSocketTask != nil else {
            if address == nil {
                log("reverse-tunnel: refused stream \(streamId) (unresolvable or blocked)")
            }
            streams.removeValue(forKey: streamId)
            send(FrameCodec.encodeClose(streamId: streamId))
            return
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            streams.removeValue(forKey: streamId)
            send(FrameCodec.encodeClose(streamId: streamId))
            return
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(address),
            port: nwPort,
            using: .tcp
        )
        entry.connection = connection
        relayedStreams += 1
        log("reverse-tunnel: relaying stream \(streamId) → \(host):\(port)")
        onStatus(getStatus())

        connection.stateUpdateHandler = { [weak self] connectionState in
            Task {
                guard let self else { return }
                switch connectionState {
                case .failed, .cancelled:
                    await self.teardownStream(streamId: streamId, connection: connection)
                default:
                    break
                }
            }
        }
        connection.start(queue: .global(qos: .utility))
        Self.receiveFromTCP(streamId: streamId, connection: connection, client: self)

        let pending = entry.pending
        entry.pending = []
        let closedByPeer = entry.closedByPeer
        for chunk in pending {
            connection.send(content: chunk, completion: .contentProcessed { _ in })
        }
        if closedByPeer {
            connection.cancel()
        }
    }

    private static func receiveFromTCP(
        streamId: UInt32,
        connection: NWConnection,
        client: ReverseTunnelClient
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            Task {
                if let data, !data.isEmpty {
                    await client.send(FrameCodec.encodeData(streamId: streamId, payload: data))
                }
                if isComplete || error != nil {
                    await client.teardownStream(streamId: streamId, connection: connection)
                    return
                }
                Self.receiveFromTCP(streamId: streamId, connection: connection, client: client)
            }
        }
    }

    private func teardownStream(streamId: UInt32, connection: NWConnection) {
        guard let entry = streams[streamId], entry.connection === connection else { return }
        streams.removeValue(forKey: streamId)
        connection.cancel()
        send(FrameCodec.encodeClose(streamId: streamId))
        onStatus(getStatus())
    }

    private func send(_ data: Data) {
        webSocketTask?.send(.data(data)) { _ in }
    }

    private static func resolveHost(_ host: String, allowPrivate: Bool) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                var hints = addrinfo(
                    ai_flags: AI_ADDRCONFIG,
                    ai_family: AF_UNSPEC,
                    ai_socktype: SOCK_STREAM,
                    ai_protocol: 0,
                    ai_addrlen: 0,
                    ai_canonname: nil,
                    ai_addr: nil,
                    ai_next: nil
                )
                var result: UnsafeMutablePointer<addrinfo>?
                let rc = getaddrinfo(host, nil, &hints, &result)
                defer { if let result { freeaddrinfo(result) } }
                guard rc == 0, let first = result else {
                    cont.resume(returning: nil)
                    return
                }
                var ptr: UnsafeMutablePointer<addrinfo>? = first
                while let info = ptr {
                    if let addr = info.pointee.ai_addr,
                       info.pointee.ai_family == AF_INET || info.pointee.ai_family == AF_INET6
                    {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(
                            addr,
                            socklen_t(info.pointee.ai_addrlen),
                            &hostname,
                            socklen_t(hostname.count),
                            nil,
                            0,
                            NI_NUMERICHOST
                        ) == 0 {
                            let ip = String(decoding: hostname.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
                            if allowPrivate || !PrivateIPGate.isBlockedDestinationIP(ip) {
                                cont.resume(returning: ip)
                                return
                            }
                        }
                    }
                    ptr = info.pointee.ai_next
                }
                cont.resume(returning: nil)
            }
        }
    }

    private func safeHost(_ urlString: String) -> String {
        URL(string: urlString)?.host ?? "(invalid-url)"
    }
}

public enum TunnelError: Error, LocalizedError, Sendable {
    case alreadyStarted
    case invalidURL(String)
    case confirmTimeout
    case missingURLAndToken
    case ensureSandBoxMissingGateway

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted: return "reverse-tunnel client already started"
        case .invalidURL(let u): return "Invalid tunnel URL: \(u)"
        case .confirmTimeout: return "Timed out waiting for box attach confirmation"
        case .missingURLAndToken:
            return "Provide --url and --token (or GROKBOT_TUNNEL_URL / GROKBOT_TUNNEL_TOKEN), or allow discovery"
        case .ensureSandBoxMissingGateway:
            return "EnsureSandBox did not return gatewayUrl/gatewayToken for reverse tunnel"
        }
    }
}

public enum AttachHeaders: Sendable {
    public static func build(
        bearer: String,
        mode: String = GrokBotTunnelConstants.attachModeClaim,
        clientId: String?,
        networkToken: String? = nil
    ) -> [String: String] {
        var headers: [String: String] = [
            "Authorization": "Bearer \(bearer)",
            GrokBotTunnelConstants.headerAttach: mode,
        ]
        if let clientId { headers[GrokBotTunnelConstants.headerClient] = clientId }
        if let networkToken, !networkToken.isEmpty {
            headers[GrokBotTunnelConstants.headerNetworkToken] = networkToken
        }
        return headers
    }
}
