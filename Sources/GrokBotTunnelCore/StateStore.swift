import Darwin
import Foundation

public struct DialerState: Codable, Sendable, Equatable {
    public var state: String
    public var mode: String?
    public var confirmed: Bool?
    public var attachGen: String?
    public var relayedStreams: Int?
    public var activeStreams: Int?
    public var lastError: String?
    public var urlHost: String?
    public var machineId: String?
    public var label: String?
    public var pid: Int32?
    public var updatedAtMs: Int64?

    public init(
        state: String,
        mode: String? = nil,
        confirmed: Bool? = nil,
        attachGen: String? = nil,
        relayedStreams: Int? = nil,
        activeStreams: Int? = nil,
        lastError: String? = nil,
        urlHost: String? = nil,
        machineId: String? = nil,
        label: String? = nil,
        pid: Int32? = nil,
        updatedAtMs: Int64? = nil
    ) {
        self.state = state
        self.mode = mode
        self.confirmed = confirmed
        self.attachGen = attachGen
        self.relayedStreams = relayedStreams
        self.activeStreams = activeStreams
        self.lastError = lastError
        self.urlHost = urlHost
        self.machineId = machineId
        self.label = label
        self.pid = pid
        self.updatedAtMs = updatedAtMs
    }
}

public enum StateStore: Sendable {
    public static func load(from paths: ConfigPaths) -> DialerState? {
        guard FileManager.default.fileExists(atPath: paths.stateURL.path),
              let data = try? Data(contentsOf: paths.stateURL),
              let state = try? JSONDecoder().decode(DialerState.self, from: data)
        else { return nil }
        return state
    }

    public static func save(_ state: DialerState, to paths: ConfigPaths) throws {
        try paths.ensureConfigDir()
        var s = state
        s.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        if s.pid == nil {
            s.pid = ProcessInfo.processInfo.processIdentifier
        }
        try atomicWrite(JSONEncoder.pretty.encode(s), to: paths.stateURL, mode: 0o600)
        if let pid = s.pid {
            let pidData = Data("\(pid)\n".utf8)
            try atomicWrite(pidData, to: paths.pidURL, mode: 0o600)
        }
    }

    public static func clear(from paths: ConfigPaths) {
        try? FileManager.default.removeItem(at: paths.stateURL)
        try? FileManager.default.removeItem(at: paths.pidURL)
    }

    public static func readPid(from paths: ConfigPaths) -> Int32? {
        if let state = load(from: paths), let pid = state.pid { return pid }
        guard let data = try? Data(contentsOf: paths.pidURL),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(text)
        else { return nil }
        return pid
    }

    public static func processAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }
}
