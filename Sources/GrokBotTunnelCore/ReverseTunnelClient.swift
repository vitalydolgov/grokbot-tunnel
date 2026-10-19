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

public final class ReverseTunnelClient: @unchecked Sendable {
    private let options: ReverseTunnelOptions
    private let log: @Sendable (String) -> Void
    private let onStatus: @Sendable (ReverseTunnelStatus) -> Void

    private let lock = NSLock()
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

    private final class StreamEntry {
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
        lock.lock()
        defer { lock.unlock() }
        return ReverseTunnelStatus(
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
        lock.lock()
        state = newState
        lock.unlock()
        onStatus(getStatus())
    }

    public func start() async throws {
        lock.lock()
        if webSocketTask != nil {
            lock.unlock()
            throw TunnelError.alreadyStarted
        }
        stopping = false
        confirmed = false
        attachGen = nil
        lastError = nil
        lock.unlock()
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

        lock.lock()
        self.session = session
        self.webSocketTask = task
        lock.unlock()

        task.resume()

        // Wait briefly for the socket to leave the suspended state.
        // URLSessionWebSocketTask does not expose a clean open event; we treat
        // successful resume + first receive loop as connected, and confirmation
        // arrives via ping/pong or first binary frame.
        setState("connected")
        log("reverse-tunnel: attached to \(safeHost(options.url)); waiting for the box to answer")

        receiveLoopTask = Task { [weak self] in
            await self?.receiveLoop()
        }

        // Send a ping to elicit confirmation (mirrors Node client).
        try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
        markConfirmed()
    }

    public func waitForConfirm(timeoutSeconds: TimeInterval = 30) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if getStatus().confirmed { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if !getStatus().confirmed {
            throw TunnelError.confirmTimeout
        }
    }

    public func runUntilStopped() async {
        while true {
            lock.lock()
            let done = stopping || webSocketTask == nil
            lock.unlock()
            if done { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
            onStatus(getStatus())
        }
    }

    public func stop() {
        lock.lock()
        stopping = true
        let task = webSocketTask
        webSocketTask = nil
        let session = self.session
        self.session = nil
        let entries = streams
        streams.removeAll()
        confirmed = false
        lock.unlock()

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
        lock.lock()
        let already = confirmed
        if !already { confirmed = true }
        lock.unlock()
        if !already {
            log("reverse-tunnel: the box confirmed the \(options.mode) attach")
            onStatus(getStatus())
        }
    }

    private func receiveLoop() async {
        while true {
            lock.lock()
            let task = webSocketTask
            let isStopping = stopping
            lock.unlock()
            guard let task, !isStopping else { return }

            do {
                let message = try await task.receive()
                markConfirmed()
                switch message {
                case .data(let data):
                    handleFrame(data)
                case .string:
                    // ignore text frames
                    break
                @unknown default:
                    break
                }
            } catch {
                lock.lock()
                if lastError == nil {
                    lastError = error.localizedDescription
                }
                let isStopping = stopping
                webSocketTask = nil
                lock.unlock()
                if !isStopping {
                    log("reverse-tunnel: socket closed: \(error.localizedDescription)")
                    setState("off")
                }
                for (_, entry) in snapshotStreams() {
                    entry.connection?.cancel()
                }
                clearStreams()
                return
            }
        }
    }

    private func handleFrame(_ raw: Data) {
        guard let frame = FrameCodec.decode(raw) else { return }
        switch frame {
        case .open(let streamId, let host, let port):
            Task { await openStream(streamId: streamId, host: host, port: port) }
        case .data(let streamId, let payload):
            lock.lock()
            let entry = streams[streamId]
            lock.unlock()
            guard let entry else { return }
            if let connection = entry.connection {
                connection.send(content: payload, completion: .contentProcessed { _ in })
            } else {
                lock.lock()
                entry.pending.append(payload)
                lock.unlock()
            }
        case .close(let streamId):
            lock.lock()
            guard let entry = streams[streamId] else {
                lock.unlock()
                return
            }
            if let connection = entry.connection {
                streams.removeValue(forKey: streamId)
                lock.unlock()
                connection.cancel()
            } else {
                entry.closedByPeer = true
                lock.unlock()
            }
        }
    }

    private func openStream(streamId: UInt32, host: String, port: UInt16) async {
        lock.lock()
        if streams[streamId] != nil {
            lock.unlock()
            send(FrameCodec.encodeClose(streamId: streamId))
            return
        }
        let entry = StreamEntry()
        streams[streamId] = entry
        lock.unlock()

        let address: String?
        if PrivateIPGate.parseIPv4(host) != nil || host.contains(":") {
            if options.allowPrivateTargets || !PrivateIPGate.isBlockedDestinationIP(host) {
                address = host
            } else {
                address = nil
            }
        } else {
            address = await resolveHost(host)
        }

        lock.lock()
        let stillOurs = streams[streamId] === entry
        let isStopping = stopping
        let hasWS = webSocketTask != nil
        lock.unlock()

        guard let address, stillOurs, !isStopping, hasWS else {
            if address == nil {
                log("reverse-tunnel: refused stream \(streamId) (unresolvable or blocked)")
            }
            lock.lock()
            streams.removeValue(forKey: streamId)
            lock.unlock()
            send(FrameCodec.encodeClose(streamId: streamId))
            return
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(address),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        lock.lock()
        entry.connection = connection
        relayedStreams += 1
        lock.unlock()
        log("reverse-tunnel: relaying stream \(streamId) → \(host):\(port)")
        onStatus(getStatus())

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                self.teardownStream(streamId: streamId, connection: connection)
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
        receiveFromTCP(streamId: streamId, connection: connection)

        lock.lock()
        let pending = entry.pending
        entry.pending = []
        let closedByPeer = entry.closedByPeer
        lock.unlock()
        for chunk in pending {
            connection.send(content: chunk, completion: .contentProcessed { _ in })
        }
        if closedByPeer {
            connection.cancel()
        }
    }

    private func receiveFromTCP(streamId: UInt32, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.send(FrameCodec.encodeData(streamId: streamId, payload: data))
            }
            if isComplete || error != nil {
                self.teardownStream(streamId: streamId, connection: connection)
                return
            }
            self.receiveFromTCP(streamId: streamId, connection: connection)
        }
    }

    private func teardownStream(streamId: UInt32, connection: NWConnection) {
        lock.lock()
        guard let entry = streams[streamId], entry.connection === connection else {
            lock.unlock()
            return
        }
        streams.removeValue(forKey: streamId)
        lock.unlock()
        connection.cancel()
        send(FrameCodec.encodeClose(streamId: streamId))
        onStatus(getStatus())
    }

    private func send(_ data: Data) {
        lock.lock()
        let task = webSocketTask
        lock.unlock()
        task?.send(.data(data)) { _ in }
    }

    private func resolveHost(_ host: String) async -> String? {
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
                       (info.pointee.ai_family == AF_INET || info.pointee.ai_family == AF_INET6)
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
                            let ip = String(cString: hostname)
                            if self.options.allowPrivateTargets || !PrivateIPGate.isBlockedDestinationIP(ip) {
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

    private func snapshotStreams() -> [UInt32: StreamEntry] {
        lock.lock()
        defer { lock.unlock() }
        return streams
    }

    private func clearStreams() {
        lock.lock()
        streams.removeAll()
        lock.unlock()
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
        case .missingURLAndToken: return "Provide --url and --token (or GROKBOT_TUNNEL_URL / GROKBOT_TUNNEL_TOKEN), or allow discovery"
        case .ensureSandBoxMissingGateway: return "EnsureSandBox did not return gatewayUrl/gatewayToken for reverse tunnel"
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
