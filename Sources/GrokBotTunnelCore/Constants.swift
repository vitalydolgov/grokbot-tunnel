import Foundation

public enum GrokBotTunnelConstants: Sendable {
    public static let defaultAPIURL = URL(string: "https://api2.cursor.sh")!
    public static let defaultWebsiteURL = URL(string: "https://cursor.com")!
    public static let defaultAuthClientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"
    public static let defaultConfigDirName = "grokbot-tunnel"
    public static let egressTunnelWSPort: UInt16 = 8790
    public static let tokenRefreshMarginSeconds: TimeInterval = 5 * 60
    public static let loginPollAttempts = 150
    public static let loginPollMaxMs: UInt64 = 10_000
    public static let clientVersion = "0.71.2"
    public static let credentialsFileName = "credentials.json"
    public static let machineFileName = "machine.json"
    public static let stateFileName = "state.json"
    public static let pidFileName = "tunnel.pid"

    public static let headerAttach = "x-sand-egress-attach"
    public static let headerClient = "x-sand-egress-client"
    public static let headerAttachGen = "x-sand-egress-attach-gen"
    public static let headerNetworkToken = "x-anyrun-network-token"
    public static let attachModeClaim = "claim"

    public static let closeReplaced = 4001
    public static let closeOccupied = 4002
}
