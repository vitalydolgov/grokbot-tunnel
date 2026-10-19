import CryptoKit
import Foundation
import Security

public struct AuthClient: Sendable {
    public var apiURL: URL
    public var websiteURL: URL
    public var clientID: String
    public var session: URLSession

    public init(
        apiURL: URL = GrokBotTunnelConstants.defaultAPIURL,
        websiteURL: URL = GrokBotTunnelConstants.defaultWebsiteURL,
        clientID: String = GrokBotTunnelConstants.defaultAuthClientID,
        session: URLSession = .shared
    ) {
        self.apiURL = apiURL
        self.websiteURL = websiteURL
        self.clientID = clientID
        self.session = session
    }

    public struct LoginSession: Sendable {
        public var loginURL: URL
        public var pollURL: URL
        public var uuid: String
        public var verifier: String
    }

    public func beginLogin() throws -> LoginSession {
        var verifierBytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, verifierBytes.count, &verifierBytes)
        guard status == errSecSuccess else {
            throw AuthError.cryptoFailure
        }
        let verifier = CursorChecksum.base64URL(Data(verifierBytes))
        let challengeDigest = Data(SHA256.hash(data: Data(verifier.utf8)))
        let challenge = CursorChecksum.base64URL(challengeDigest)
        let uuid = UUID().uuidString.lowercased()

        var loginComponents = URLComponents(
            url: websiteURL.appendingPathComponent("loginDeepControl"),
            resolvingAgainstBaseURL: false
        )!
        loginComponents.queryItems = [
            URLQueryItem(name: "challenge", value: challenge),
            URLQueryItem(name: "uuid", value: uuid),
            URLQueryItem(name: "mode", value: "login"),
            URLQueryItem(name: "redirectTarget", value: "sand"),
            URLQueryItem(name: "supportsSelectedTeamLogin", value: "true"),
        ]
        guard let loginURL = loginComponents.url else { throw AuthError.invalidURL }

        var pollComponents = URLComponents(
            url: apiURL.appendingPathComponent("auth/poll"),
            resolvingAgainstBaseURL: false
        )!
        pollComponents.queryItems = [
            URLQueryItem(name: "uuid", value: uuid),
            URLQueryItem(name: "verifier", value: verifier),
        ]
        guard let pollURL = pollComponents.url else { throw AuthError.invalidURL }

        return LoginSession(loginURL: loginURL, pollURL: pollURL, uuid: uuid, verifier: verifier)
    }

    public func pollForTokens(pollURL: URL) async throws -> Credentials {
        var delayMs: UInt64 = 1000
        for _ in 0..<GrokBotTunnelConstants.loginPollAttempts {
            var request = URLRequest(url: pollURL)
            request.httpMethod = "GET"
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
            if http.statusCode == 404 {
                try await Task.sleep(nanoseconds: delayMs * 1_000_000)
                delayMs = min(UInt64(Double(delayMs) * 1.2), GrokBotTunnelConstants.loginPollMaxMs)
                continue
            }
            let body = try decodeJSONObject(data, action: "OAuth poll", status: http.statusCode)
            if !(200..<300).contains(http.statusCode) {
                let message = (body["message"] as? String)
                    ?? (body["error"] as? String)
                    ?? "unknown error"
                throw AuthError.httpError(status: http.statusCode, message: message)
            }
            let access = (body["accessToken"] as? String) ?? (body["access_token"] as? String)
            let refresh = (body["refreshToken"] as? String) ?? (body["refresh_token"] as? String)
            guard let access, !access.isEmpty, let refresh, !refresh.isEmpty else {
                throw AuthError.missingTokens
            }
            let team: String? = {
                guard let value = body["selectedTeamId"] else { return nil }
                if let s = value as? String { return s }
                if let n = value as? NSNumber { return n.stringValue }
                return nil
            }()
            return Credentials(accessToken: access, refreshToken: refresh, selectedTeamId: team)
        }
        throw AuthError.timeout
    }

    public func refreshIfNeeded(_ credentials: Credentials, paths: ConfigPaths) async throws -> Credentials {
        guard JWTHelpers.tokenExpiresSoon(credentials.accessToken) else { return credentials }
        let url = apiURL.appendingPathComponent("oauth/token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
        let obj = try decodeJSONObject(data, action: "OAuth refresh", status: http.statusCode)
        if obj["shouldLogout"] as? Bool == true {
            throw AuthError.requiresReLogin
        }
        if !(200..<300).contains(http.statusCode) {
            let message = (obj["message"] as? String) ?? (obj["error"] as? String) ?? "unknown error"
            throw AuthError.httpError(status: http.statusCode, message: message)
        }
        let access = (obj["accessToken"] as? String) ?? (obj["access_token"] as? String) ?? credentials.accessToken
        let refresh = (obj["refreshToken"] as? String) ?? (obj["refresh_token"] as? String) ?? credentials.refreshToken
        var updated = credentials
        updated.accessToken = access
        updated.refreshToken = refresh
        try CredentialStore.save(updated, to: paths)
        return updated
    }

    public func authHeaders(machineId: String, credentials: Credentials) -> [String: String] {
        var headers: [String: String] = [
            "authorization": "Bearer \(credentials.accessToken)",
            "x-cursor-checksum": CursorChecksum.make(machineId: machineId),
            "x-cursor-client-type": "sand",
            "x-cursor-client-version": GrokBotTunnelConstants.clientVersion,
            "x-sand-box-namespace": "prod",
            "x-ghost-mode": "true",
            "x-request-id": UUID().uuidString.lowercased(),
        ]
        if let team = credentials.selectedTeamId, !team.isEmpty {
            headers["x-cursor-team-id"] = team
        }
        return headers
    }

    public func connectUnary(
        service: String,
        method: String,
        requestBody: [String: Any],
        credentials: Credentials,
        machineId: String
    ) async throws -> [String: Any] {
        let url = apiURL.appendingPathComponent("\(service)/\(method)")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        var headers = authHeaders(machineId: machineId, credentials: credentials)
        headers["content-type"] = "application/json"
        headers["connect-protocol-version"] = "1"
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
        let obj = try decodeJSONObject(data, action: method, status: http.statusCode)
        if !(200..<300).contains(http.statusCode) {
            let message = (obj["message"] as? String) ?? (obj["error"] as? String) ?? "unknown error"
            throw AuthError.httpError(status: http.statusCode, message: message)
        }
        return obj
    }

    public func ensureSandBox(credentials: Credentials, machineId: String) async throws -> SandBoxDescriptor {
        let obj = try await connectUnary(
            service: "aiserver.v1.SandBoxService",
            method: "EnsureSandBox",
            requestBody: ["wake": true, "supportsAsleepBox": true],
            credentials: credentials,
            machineId: machineId
        )
        return SandBoxDescriptor(json: obj)
    }
}

public struct SandBoxDescriptor: Sendable {
    public var gatewayUrl: String?
    public var gatewayToken: String?
    public var networkToken: String?
    public var vncUrl: String?
    public var forkVncBaseUrl: String?
    public var egressTunnelOwnership: Bool?

    public init(json: [String: Any]) {
        gatewayUrl = json["gatewayUrl"] as? String
        gatewayToken = json["gatewayToken"] as? String
        networkToken = json["networkToken"] as? String
        vncUrl = json["vncUrl"] as? String
        forkVncBaseUrl = json["forkVncBaseUrl"] as? String
        if let b = json["egressTunnelOwnership"] as? Bool {
            egressTunnelOwnership = b
        }
    }
}

public enum AuthError: Error, LocalizedError, Sendable {
    case cryptoFailure
    case invalidURL
    case invalidResponse
    case missingTokens
    case timeout
    case requiresReLogin
    case httpError(status: Int, message: String)
    case notLoggedIn

    public var errorDescription: String? {
        switch self {
        case .cryptoFailure: return "Failed to generate secure random bytes"
        case .invalidURL: return "Invalid auth URL"
        case .invalidResponse: return "Invalid HTTP response"
        case .missingTokens: return "OAuth response did not contain access and refresh tokens"
        case .timeout: return "OAuth sign-in timed out"
        case .requiresReLogin: return "OAuth refresh requires a new sign-in"
        case .httpError(let status, let message): return "HTTP \(status): \(message)"
        case .notLoggedIn: return "No valid account credentials. Run: grokbot-tunnel login"
        }
    }
}

func decodeJSONObject(_ data: Data, action: String, status: Int) throws -> [String: Any] {
    if data.isEmpty { return [:] }
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AuthError.httpError(status: status, message: "\(action) returned invalid JSON")
    }
    return obj
}
