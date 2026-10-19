import Foundation

public enum GatewayRewrite: Sendable {
    /// Rewrite a box gateway HTTP(S) URL to the reverse-tunnel WebSocket endpoint.
    /// When `useVncHostnameRewrite` is true, replace the trailing -<digits> of the
    /// first hostname label with -8790. Otherwise set the port to 8790.
    public static func rewriteGatewayToTunnelWs(
        _ gatewayUrl: String,
        useVncHostnameRewrite: Bool = false
    ) -> String? {
        guard var components = URLComponents(string: gatewayUrl) else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }

        if useVncHostnameRewrite {
            let labels = host.split(separator: ".", omittingEmptySubsequences: false)
            guard let first = labels.first else { return nil }
            let firstString = String(first)
            guard firstString.range(of: "-\\d+$", options: .regularExpression) != nil else {
                return nil
            }
            let rewrittenFirst = firstString.replacingOccurrences(
                of: "-\\d+$",
                with: "-\(GrokBotTunnelConstants.egressTunnelWSPort)",
                options: .regularExpression
            )
            var newLabels = labels.map(String.init)
            newLabels[0] = rewrittenFirst
            components.host = newLabels.joined(separator: ".")
            components.port = nil
        } else {
            components.port = Int(GrokBotTunnelConstants.egressTunnelWSPort)
        }

        let scheme = components.scheme?.lowercased() ?? "https"
        if scheme == "https" || scheme == "wss" {
            components.scheme = "wss"
        } else {
            components.scheme = "ws"
        }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        return components.string
    }

    public struct TunnelConfig: Sendable, Equatable {
        public var url: String
        public var bearer: String
        public var networkToken: String?

        public init(url: String, bearer: String, networkToken: String? = nil) {
            self.url = url
            self.bearer = bearer
            self.networkToken = networkToken
        }
    }

    /// Build tunnel dial config from an EnsureSandBox-style gateway descriptor.
    public static func tunnelConfigFromBox(
        gatewayUrl: String?,
        gatewayToken: String?,
        networkToken: String? = nil,
        vncUrl: String? = nil,
        forkVncBaseUrl: String? = nil
    ) -> TunnelConfig? {
        guard let gatewayUrl, !gatewayUrl.isEmpty,
              let gatewayToken, !gatewayToken.isEmpty
        else { return nil }

        let net = networkToken ?? ""
        let vnc = vncUrl ?? ""
        let fork = forkVncBaseUrl ?? ""
        let useVnc = !net.isEmpty && !vnc.isEmpty && !fork.isEmpty
        guard let url = rewriteGatewayToTunnelWs(gatewayUrl, useVncHostnameRewrite: useVnc) else {
            return nil
        }
        return TunnelConfig(
            url: url,
            bearer: gatewayToken,
            networkToken: net.isEmpty ? nil : net
        )
    }
}
