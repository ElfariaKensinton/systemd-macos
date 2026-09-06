import Foundation

public enum UnitType: String, Codable, Sendable {
    case service
}

public enum ServiceType: String, Codable, Sendable {
    case simple
    case exec
    case forking
    case oneshot
    case notify
    case idle
}

public enum RestartPolicy: String, Codable, Sendable {
    case no
    case onSuccess = "on-success"
    case onFailure = "on-failure"
    case onAbnormal = "on-abnormal"
    case onWatchdog = "on-watchdog"
    case onAbort = "on-abort"
    case always
}

public struct UnitFile: Sendable {
    public var name: String
    public var path: URL
    public var description: String?
    public var documentation: [String]
    public var requires: [String]
    public var wants: [String]
    public var after: [String]
    public var before: [String]
    public var conflicts: [String]
    public var service: ServiceConfig
    public var wantedBy: [String]
    public var aliases: [String]

    public init(name: String, path: URL, description: String? = nil,
                documentation: [String] = [], requires: [String] = [],
                wants: [String] = [], after: [String] = [], before: [String] = [],
                conflicts: [String] = [], service: ServiceConfig = .init(),
                wantedBy: [String] = [], aliases: [String] = []) {
        self.name = name
        self.path = path
        self.description = description
        self.documentation = documentation
        self.requires = requires
        self.wants = wants
        self.after = after
        self.before = before
        self.conflicts = conflicts
        self.service = service
        self.wantedBy = wantedBy
        self.aliases = aliases
    }
}

public struct ServiceConfig: Sendable {
    public var type: ServiceType = .simple
    public var execStart: [String] = []
    public var execStartPre: [String] = []
    public var execStartPost: [String] = []
    public var execStop: [String] = []
    public var restart: RestartPolicy = .no
    public var restartSec: TimeInterval = 100ms
    public var timeoutStartSec: TimeInterval = 90
    public var timeoutStopSec: TimeInterval = 90
    public var user: String?
    public var group: String?
    public var workingDirectory: String?
    public var environment: [String: String] = [:]
    public var environmentFiles: [String] = []
    public var remainAfterExit = false
    public var killSignal: Int32 = 15
    public var standardOutput: String = "journal"
    public var standardError: String = "inherit"

    public init() {}
}

private let `100ms`: TimeInterval = 0.1

public struct UnitStatus: Codable, Sendable {
    public var name: String
    public var description: String?
    public var loadState: String
    public var activeState: String
    public var subState: String
    public var mainPID: Int32
    public var enabled: Bool
    public var path: String?
    public var result: String

    public init(name: String, description: String?, loadState: String, activeState: String,
                subState: String, mainPID: Int32, enabled: Bool, path: String?, result: String) {
        self.name = name
        self.description = description
        self.loadState = loadState
        self.activeState = activeState
        self.subState = subState
        self.mainPID = mainPID
        self.enabled = enabled
        self.path = path
        self.result = result
    }
}

public enum ManagerError: Error, LocalizedError, Sendable {
    case invalidUnitName(String)
    case unitNotFound(String)
    case unitAlreadyActive(String)
    case unitInactive(String)
    case invalidConfiguration(String)
    case dependencyCycle([String])
    case commandFailed(String, Int32)
    case ipc(String)
    case permission(String)

    public var errorDescription: String? {
        switch self {
        case .invalidUnitName(let value): return "Invalid unit name: \(value)"
        case .unitNotFound(let value): return "Unit \"\(value)\" not found."
        case .unitAlreadyActive(let value): return "Unit \"\(value)\" is already active."
        case .unitInactive(let value): return "Unit \"\(value)\" is not active."
        case .invalidConfiguration(let value): return "Invalid unit configuration: \(value)"
        case .dependencyCycle(let values): return "Dependency cycle: \(values.joined(separator: " -> "))"
        case .commandFailed(let command, let status): return "Command \"\(command)\" failed with status \(status)."
        case .ipc(let value): return "IPC error: \(value)"
        case .permission(let value): return "Permission denied: \(value)"
        }
    }
}
