import Foundation

public struct TerminalPreviewActivityMessage: Sendable, Equatable {
    public let agentPID: Int
    public let clientPID: Int
    public let isVisible: Bool

    public init(agentPID: Int, clientPID: Int, isVisible: Bool) {
        self.agentPID = agentPID
        self.clientPID = clientPID
        self.isVisible = isVisible
    }

    public init?(userInfo: [AnyHashable: Any]?) {
        guard let agent = userInfo?["agent_pid"] as? Int, agent > 0,
              let client = userInfo?["client_pid"] as? Int, client > 0,
              Int32(exactly: agent) != nil, Int32(exactly: client) != nil,
              let visible = userInfo?["visible"] as? Bool else { return nil }
        self.init(agentPID: agent, clientPID: client, isVisible: visible)
    }

    public var userInfo: [AnyHashable: Any] {
        ["agent_pid": agentPID, "client_pid": clientPID, "visible": isVisible]
    }
}

/// A visible preview needs the shared producer even when Desktop presentation
/// is paused. Expiry releases demand after a closed or crashed GUI.
public struct TerminalPreviewActivity: Sendable {
    private var clients: [Int: TimeInterval] = [:]

    public init() {}

    public mutating func update(clientPID: Int, visible: Bool, at uptime: TimeInterval) {
        guard clientPID > 0 else { return }
        if visible { clients[clientPID] = uptime }
        else { clients.removeValue(forKey: clientPID) }
    }

    public mutating func hasVisibleClient(at uptime: TimeInterval, processIsRunning: (Int) -> Bool) -> Bool {
        clients = clients.filter {
            let age = uptime - $0.value
            return age >= 0 && age < 2 && processIsRunning($0.key)
        }
        return !clients.isEmpty
    }
}
