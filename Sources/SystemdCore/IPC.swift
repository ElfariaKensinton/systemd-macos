import Foundation

public enum SystemctlAction: String, Codable, Sendable {
    case start
    case stop
    case restart
    case reload
    case status
    case enable
    case disable
    case isActive = "is-active"
    case isEnabled = "is-enabled"
    case daemonReload = "daemon-reload"
    case listUnits = "list-units"
    case listUnitFiles = "list-unit-files"
    case cat
    case show
}

public struct IPCRequest: Codable, Sendable {
    public var action: SystemctlAction
    public var units: [String]
    public var extra: [String: String]

    public init(action: SystemctlAction, units: [String] = [], extra: [String: String] = [:]) {
        self.action = action
        self.units = units
        self.extra = extra
    }
}

public struct IPCResponse: Codable, Sendable {
    public var exitCode: Int32
    public var output: String
    public var error: String?
    public var statuses: [UnitStatus]

    public init(exitCode: Int32, output: String = "", error: String? = nil, statuses: [UnitStatus] = []) {
        self.exitCode = exitCode
        self.output = output
        self.error = error
        self.statuses = statuses
    }
}

public enum SystemdPaths {
    public static let socket = URL(fileURLWithPath: "/var/run/systemd-macos.sock")
    public static let systemUnitDirectory = URL(fileURLWithPath: "/etc/systemd/system", isDirectory: true)
    public static let vendorUnitDirectory = URL(fileURLWithPath: "/usr/local/lib/systemd/system", isDirectory: true)
    public static let userUnitDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/systemd/user", isDirectory: true)
    public static let stateDirectory = URL(fileURLWithPath: "/var/lib/systemd-macos", isDirectory: true)
    public static let enablementDirectory = stateDirectory.appendingPathComponent("enabled", isDirectory: true)
    public static let logDirectory = stateDirectory.appendingPathComponent("log", isDirectory: true)
}

public final class LineCodec {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        try decoder.decode(type, from: line)
    }
}
