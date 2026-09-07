import Foundation

public struct UnitParser: Sendable {
    public init() {}

    public func parse(url: URL) throws -> UnitFile {
        var text = try String(contentsOf: url, encoding: .utf8)
        let name = url.lastPathComponent

        // Apply persistent drop-ins first, then runtime drop-ins so the
        // runtime configuration has the same precedence as systemd.
        let persistentDropIn = url.deletingLastPathComponent().appendingPathComponent("\(name).d", isDirectory: true)
        text += try readDropIns(from: persistentDropIn)
        let runtimeDropIn = SystemdPaths.runtimeUnitDirectory.appendingPathComponent("\(name).d", isDirectory: true)
        if runtimeDropIn.path != persistentDropIn.path {
            text += try readDropIns(from: runtimeDropIn)
        }
        return try parse(text: text, name: name, path: url)
    }

    private func readDropIns(from directory: URL) throws -> String {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return "" }
        return try names.filter { $0.hasSuffix(".conf") }.sorted().map { name in
            let url = directory.appendingPathComponent(name)
            return "\n" + (try String(contentsOf: url, encoding: .utf8)) + "\n"
        }.joined()
    }

    public func parse(text: String, name: String, path: URL = URL(fileURLWithPath: "")) throws -> UnitFile {
        guard name.hasSuffix(".service") else {
            throw ManagerError.invalidUnitName(name)
        }

        var section = ""
        var description: String?
        var documentation: [String] = []
        var requires: [String] = []
        var wants: [String] = []
        var after: [String] = []
        var before: [String] = []
        var conflicts: [String] = []
        var wantedBy: [String] = []
        var aliases: [String] = []
        var service = ServiceConfig()

        for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).lowercased()
                guard ["unit", "service", "install"].contains(section) else {
                    throw ManagerError.invalidConfiguration("unknown section at line \(index + 1): \(line)")
                }
                continue
            }

            guard let equals = line.firstIndex(of: "=") else {
                throw ManagerError.invalidConfiguration("missing '=' at line \(index + 1)")
            }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)

            switch section {
            case "unit":
                switch key {
                case "Description": description = value
                case "Documentation": documentation += splitWords(value)
                case "Requires": requires += splitWords(value)
                case "Wants": wants += splitWords(value)
                case "After": after += splitWords(value)
                case "Before": before += splitWords(value)
                case "Conflicts": conflicts += splitWords(value)
                default: break
                }
            case "service":
                try assignService(key: key, value: value, service: &service)
            case "install":
                switch key {
                case "WantedBy": wantedBy += splitWords(value)
                case "Alias": aliases += splitWords(value)
                default: break
                }
            default:
                throw ManagerError.invalidConfiguration("setting outside a section at line \(index + 1)")
            }
        }

        guard !service.execStart.isEmpty || service.type == .oneshot else {
            throw ManagerError.invalidConfiguration("[Service] ExecStart= is required for \(name)")
        }

        return UnitFile(name: name, path: path, description: description,
                        documentation: documentation, requires: requires, wants: wants,
                        after: after, before: before, conflicts: conflicts, service: service,
                        wantedBy: wantedBy, aliases: aliases)
    }

    private func splitWords(_ value: String) -> [String] {
        value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private func assignService(key: String, value: String, service: inout ServiceConfig) throws {
        switch key {
        case "Type":
            guard let value = ServiceType(rawValue: value) else { throw ManagerError.invalidConfiguration("unsupported Type=\(value)") }
            service.type = value
        case "ExecStart": service.execStart = value.isEmpty ? [] : [value]
        case "ExecStartPre": service.execStartPre.append(value)
        case "ExecStartPost": service.execStartPost.append(value)
        case "ExecStop": service.execStop.append(value)
        case "Restart":
            guard let value = RestartPolicy(rawValue: value) else { throw ManagerError.invalidConfiguration("unsupported Restart=\(value)") }
            service.restart = value
        case "RestartSec": service.restartSec = try parseDuration(value)
        case "TimeoutStartSec": service.timeoutStartSec = try parseDuration(value)
        case "TimeoutStopSec": service.timeoutStopSec = try parseDuration(value)
        case "User": service.user = value
        case "Group": service.group = value
        case "SupplementaryGroups": service.supplementaryGroups = splitWords(value)
        case "WorkingDirectory": service.workingDirectory = value
        case "UMask": service.umask = try parseUMask(value)
        case "LimitNOFILE": service.limitNOFILE = try parseLimitNOFILE(value)
        case "CapabilityBoundingSet": service.capabilityBoundingSet = splitWords(value).map { $0.uppercased() }
        case "AmbientCapabilities": service.ambientCapabilities = splitWords(value).map { $0.uppercased() }
        case "NoNewPrivileges": service.noNewPrivileges = try parseBool(value)
        case "Environment":
            let assignment = try parseAssignment(value)
            service.environment[assignment.0] = assignment.1
        case "EnvironmentFile": service.environmentFiles.append(value)
        case "RemainAfterExit": service.remainAfterExit = try parseBool(value)
        case "KillSignal": service.killSignal = try parseSignal(value)
        case "StandardOutput": service.standardOutput = value
        case "StandardError": service.standardError = value
        default: break
        }
    }

    private func parseLimitNOFILE(_ value: String) throws -> UInt64 {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard value != "infinity", let limit = UInt64(value) else {
            throw ManagerError.invalidConfiguration("unsupported LimitNOFILE=\(value)")
        }
        return limit
    }

    private func parseUMask(_ value: String) throws -> UInt16 {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.allSatisfy({ $0.isNumber && $0 < "8" }) else {
            throw ManagerError.invalidConfiguration("invalid UMask=\(value)")
        }
        guard let mask = UInt16(value, radix: 8), mask <= 0o777 else {
            throw ManagerError.invalidConfiguration("invalid UMask=\(value)")
        }
        return mask
    }

    private func parseAssignment(_ value: String) throws -> (String, String) {
        let stripped = value.hasPrefix("\"") && value.hasSuffix("\"") ? String(value.dropFirst().dropLast()) : value
        guard let index = stripped.firstIndex(of: "=") else {
            throw ManagerError.invalidConfiguration("Environment= must be KEY=VALUE")
        }
        let key = String(stripped[..<index])
        let val = String(stripped[stripped.index(after: index)...])
        guard !key.isEmpty else { throw ManagerError.invalidConfiguration("environment variable name is empty") }
        return (key, val)
    }

    private func parseBool(_ value: String) throws -> Bool {
        switch value.lowercased() {
        case "yes", "true", "1": return true
        case "no", "false", "0": return false
        default: throw ManagerError.invalidConfiguration("invalid boolean \(value)")
        }
    }

    private func parseSignal(_ value: String) throws -> Int32 {
        if let integer = Int32(value) { return integer }
        let signal = value.uppercased().hasPrefix("SIG") ? String(value.uppercased().dropFirst(3)) : value.uppercased()
        let table: [String: Int32] = ["HUP": 1, "INT": 2, "QUIT": 3, "ABRT": 6, "KILL": 9, "TERM": 15, "STOP": 19, "CONT": 18]
        guard let number = table[signal] else { throw ManagerError.invalidConfiguration("unknown signal \(value)") }
        return number
    }

    public func parseDuration(_ value: String) throws -> TimeInterval {
        let value = value.lowercased().trimmingCharacters(in: .whitespaces)
        if value == "infinity" { return .greatestFiniteMagnitude }
        var numberEnd = value.startIndex
        while numberEnd < value.endIndex && (value[numberEnd].isNumber || value[numberEnd] == ".") {
            numberEnd = value.index(after: numberEnd)
        }
        guard numberEnd > value.startIndex, let number = Double(value[..<numberEnd]) else {
            throw ManagerError.invalidConfiguration("invalid duration \(value)")
        }
        let suffix = String(value[numberEnd...])
        switch suffix {
        case "", "s", "sec", "seconds": return number
        case "ms", "msec", "milliseconds": return number / 1000
        case "m", "min", "minutes": return number * 60
        case "h", "hours": return number * 3600
        case "d", "days": return number * 86400
        default: throw ManagerError.invalidConfiguration("unsupported duration suffix \(suffix)")
        }
    }
}
