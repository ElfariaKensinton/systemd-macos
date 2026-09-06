import Foundation
#if canImport(Darwin)
import Darwin
#endif

public final class ServiceManager: @unchecked Sendable {
    private struct Runtime {
        var process: Process?
        var startedAt: Date?
        var state: String
        var result: String
        var mainPID: Int32
        var stopRequested: Bool

        init(state: String = "dead", result: String = "success", mainPID: Int32 = 0) {
            self.process = nil
            self.startedAt = nil
            self.state = state
            self.result = result
            self.mainPID = mainPID
            self.stopRequested = false
        }
    }

    private let parser = UnitParser()
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var units: [String: UnitFile] = [:]
    private var runtime: [String: Runtime] = [:]
    private var enabled: Set<String> = []
    private let unitDirectories: [URL]

    public init(unitDirectories: [URL] = [SystemdPaths.systemUnitDirectory, SystemdPaths.vendorUnitDirectory]) {
        self.unitDirectories = unitDirectories
        load()
    }

    public func load() {
        lock.lock(); defer { lock.unlock() }
        var loaded: [String: UnitFile] = [:]
        for directory in unitDirectories {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where name.hasSuffix(".service") {
                let url = directory.appendingPathComponent(name)
                if let unit = try? parser.parse(url: url) { loaded[name] = unit }
            }
        }
        units = loaded

        if let names = try? fileManager.contentsOfDirectory(atPath: SystemdPaths.enablementDirectory.path) {
            enabled = Set(names.filter { $0.hasSuffix(".service") })
        }
        for name in units.keys where runtime[name] == nil { runtime[name] = Runtime() }
    }

    public func startEnabledUnits() {
        let names: [String]
        lock.lock(); names = enabled.sorted(); lock.unlock()
        for name in names { try? start(name) }
    }

    public func status(_ name: String) throws -> UnitStatus {
        let normalized = normalize(name)
        lock.lock(); defer { lock.unlock() }
        guard let unit = units[normalized] else { throw ManagerError.unitNotFound(normalized) }
        let state = runtime[normalized] ?? Runtime()
        return UnitStatus(name: normalized, description: unit.description,
                          loadState: "loaded", activeState: state.state == "active" ? "active" : "inactive",
                          subState: state.state, mainPID: state.mainPID,
                          enabled: enabled.contains(normalized), path: unit.path.path, result: state.result,
                          activeSince: state.startedAt)
    }

    public func listUnits() -> [UnitStatus] {
        lock.lock(); defer { lock.unlock() }
        return units.keys.sorted().compactMap { name in
            guard let unit = units[name] else { return nil }
            let state = runtime[name] ?? Runtime()
            return UnitStatus(name: name, description: unit.description,
                              loadState: "loaded", activeState: state.state == "active" ? "active" : "inactive",
                              subState: state.state, mainPID: state.mainPID,
                              enabled: enabled.contains(name), path: unit.path.path, result: state.result,
                              activeSince: state.startedAt)
        }
    }

    public func listUnitFiles() -> [UnitStatus] { listUnits() }

    public func start(_ name: String) throws {
        let normalized = normalize(name)
        var visiting: Set<String> = []
        try startRecursive(normalized, visiting: &visiting)
    }

    private func startRecursive(_ name: String, visiting: inout Set<String>) throws {
        if visiting.contains(name) { throw ManagerError.dependencyCycle(Array(visiting) + [name]) }
        visiting.insert(name)
        defer { visiting.remove(name) }

        let unit: UnitFile
        lock.lock()
        guard let found = units[name] else { lock.unlock(); throw ManagerError.unitNotFound(name) }
        unit = found
        let alreadyActive = runtime[name]?.state == "active"
        lock.unlock()
        if alreadyActive { return }

        for dependency in unit.requires + unit.wants {
            try startRecursive(normalize(dependency), visiting: &visiting)
        }
        for dependency in unit.conflicts {
            if let depStatus = try? status(dependency), depStatus.activeState == "active" { try stop(dependency) }
        }
        try launch(unit)
    }

    public func stop(_ name: String) throws {
        let normalized = normalize(name)
        let unit: UnitFile
        let process: Process?
        lock.lock()
        guard let found = units[normalized] else { lock.unlock(); throw ManagerError.unitNotFound(normalized) }
        unit = found
        process = runtime[normalized]?.process
        runtime[normalized]?.stopRequested = true
        lock.unlock()

        if let command = unit.service.execStop.first {
            _ = try? run(command, unit: unit)
        }

        if let process, process.isRunning {
            #if canImport(Darwin)
            kill(process.processIdentifier, unit.service.killSignal)
            #endif
            let deadline = Date().addingTimeInterval(unit.service.timeoutStopSec)
            while process.isRunning && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            if process.isRunning { process.terminate() }
        }

        lock.lock()
        runtime[normalized] = Runtime(state: unit.service.remainAfterExit ? "exited" : "dead", result: "success", mainPID: 0)
        lock.unlock()
    }

    public func restart(_ name: String) throws {
        let normalized = normalize(name)
        if let current = try? status(normalized), current.activeState == "active" { try stop(normalized) }
        try start(normalized)
    }

    public func enable(_ name: String) throws {
        let normalized = normalize(name)
        lock.lock()
        guard let unit = units[normalized] else { lock.unlock(); throw ManagerError.unitNotFound(normalized) }
        let aliases = unit.aliases
        lock.unlock()
        try fileManager.createDirectory(at: SystemdPaths.enablementDirectory, withIntermediateDirectories: true)
        let marker = SystemdPaths.enablementDirectory.appendingPathComponent(normalized)
        if !fileManager.fileExists(atPath: marker.path) { try Data().write(to: marker) }
        for alias in aliases {
            let aliasMarker = SystemdPaths.enablementDirectory.appendingPathComponent(normalize(alias))
            if !fileManager.fileExists(atPath: aliasMarker.path) { try Data().write(to: aliasMarker) }
        }
        lock.lock(); enabled.insert(normalized); lock.unlock()
    }

    public func disable(_ name: String) throws {
        let normalized = normalize(name)
        let aliases: [String]
        lock.lock()
        guard let unit = units[normalized] else { lock.unlock(); throw ManagerError.unitNotFound(normalized) }
        aliases = unit.aliases
        lock.unlock()
        let marker = SystemdPaths.enablementDirectory.appendingPathComponent(normalized)
        try? fileManager.removeItem(at: marker)
        for alias in aliases { try? fileManager.removeItem(at: SystemdPaths.enablementDirectory.appendingPathComponent(normalize(alias))) }
        lock.lock(); enabled.remove(normalized); lock.unlock()
    }

    public func cat(_ name: String) throws -> String {
        let normalized = normalize(name)
        lock.lock(); defer { lock.unlock() }
        guard let unit = units[normalized] else { throw ManagerError.unitNotFound(normalized) }
        return try String(contentsOf: unit.path, encoding: .utf8)
    }

    public func show(_ name: String) throws -> [String: String] {
        let status = try status(name)
        return [
            "Id": status.name,
            "Description": status.description ?? "",
            "LoadState": status.loadState,
            "ActiveState": status.activeState,
            "SubState": status.subState,
            "MainPID": String(status.mainPID),
            "UnitFileState": status.enabled ? "enabled" : "disabled",
            "Result": status.result,
            "FragmentPath": status.path ?? ""
        ]
    }

    private func launch(_ unit: UnitFile) throws {
        try validatePermissionConfiguration(unit)
        for command in unit.service.execStartPre {
            _ = try run(command, unit: unit)
        }
        guard let command = unit.service.execStart.first else {
            lock.lock(); runtime[unit.name] = Runtime(state: "exited", result: "success", mainPID: 0); lock.unlock(); return
        }

        let process = Process()
        let invocation = try commandInvocation(command: command, unit: unit)
        process.launchPath = invocation.executable
        process.arguments = invocation.arguments
        process.environment = environment(for: unit)
        if let directory = unit.service.workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }

        let outURL = try logURL(for: unit, stream: "stdout")
        let errURL = try logURL(for: unit, stream: "stderr")
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let outputMode = unit.service.standardOutput.lowercased()
        let errorMode = unit.service.standardError.lowercased()
        if outputMode == "null" {
            process.standardOutput = FileHandle.nullDevice
        } else {
            process.standardOutput = stdoutPipe
            try truncateLog(outURL)
        }
        if errorMode == "null" {
            process.standardError = FileHandle.nullDevice
        } else {
            process.standardError = stderrPipe
            try truncateLog(errURL)
        }

        lock.lock()
        runtime[unit.name] = Runtime(state: "activating", result: "success", mainPID: 0)
        runtime[unit.name]?.process = process
        lock.unlock()

        if outputMode != "null" { startLogReader(stdoutPipe.fileHandleForReading, url: outURL) }
        if errorMode != "null" { startLogReader(stderrPipe.fileHandleForReading, url: errURL) }

        do {
            try process.run()
        } catch {
            lock.lock()
            runtime[unit.name] = Runtime(state: "dead", result: "exit-code", mainPID: 0)
            lock.unlock()
            throw error
        }

        lock.lock()
        runtime[unit.name]?.startedAt = Date()
        runtime[unit.name]?.mainPID = process.processIdentifier
        runtime[unit.name]?.state = "active"
        lock.unlock()

        let jobCheckDeadline = Date().addingTimeInterval(1.0)
        while process.isRunning && Date() < jobCheckDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }

        if !process.isRunning {
            process.waitUntilExit()
            let status = process.terminationStatus
            handleExit(unit: unit, status: status, allowRestart: false)
            if status != 0 {
                throw ManagerError.commandFailed(command, status)
            }
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self, weak process] in
            guard let self, let process else { return }
            process.waitUntilExit()
            self.handleExit(unit: unit, status: process.terminationStatus)
        }

        for command in unit.service.execStartPost {
            _ = try? run(command, unit: unit)
        }
    }

    private func handleExit(unit: UnitFile, status: Int32, allowRestart: Bool = true) {
        lock.lock()
        let requested = runtime[unit.name]?.stopRequested ?? false
        let shouldRestart: Bool
        switch unit.service.restart {
        case .always: shouldRestart = allowRestart && !requested
        case .onSuccess: shouldRestart = allowRestart && status == 0 && !requested
        case .onFailure, .onAbnormal, .onWatchdog, .onAbort: shouldRestart = allowRestart && status != 0 && !requested
        case .no: shouldRestart = false
        }
        runtime[unit.name]?.process = nil
        runtime[unit.name]?.mainPID = 0
        runtime[unit.name]?.state = unit.service.remainAfterExit ? "exited" : "dead"
        runtime[unit.name]?.result = status == 0 ? "success" : "exit-code"
        lock.unlock()

        if shouldRestart {
            Thread.sleep(forTimeInterval: unit.service.restartSec)
            try? start(unit.name)
        }
    }

    private func run(_ command: String, unit: UnitFile) throws -> Int32 {
        let process = Process()
        let invocation = try commandInvocation(command: command, unit: unit)
        process.launchPath = invocation.executable
        process.arguments = invocation.arguments
        process.environment = environment(for: unit)
        if let directory = unit.service.workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw ManagerError.commandFailed(command, process.terminationStatus) }
        return process.terminationStatus
    }

    private func truncateLog(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            try handle.close()
        } else {
            fileManager.createFile(atPath: url.path, contents: Data())
        }
    }

    private func startLogReader(_ handle: FileHandle, url: URL) {
        DispatchQueue.global(qos: .utility).async { [fileManager] in
            while true {
                let data = handle.readData(ofLength: 8192)
                if data.isEmpty { break }
                guard let output = try? FileHandle(forWritingTo: url) else { break }
                do {
                    try output.seekToEnd()
                    try output.write(contentsOf: data)
                    try output.close()
                } catch {
                    try? output.close()
                    break
                }
            }
            try? handle.close()
        }
        _ = fileManager
    }

    private func commandInvocation(command: String, unit: UnitFile) throws -> (executable: String, arguments: [String]) {
        var setup: [String] = []
        if let umask = unit.service.umask { setup.append("umask \(String(umask, radix: 8))") }
        if let limitNOFILE = unit.service.limitNOFILE { setup.append("ulimit -n \(limitNOFILE) || exit $?") }
        let shellScript = (setup + ["exec /bin/sh -c \(shellQuote(command))"]).joined(separator: "\n")

        let needsHelper = unit.service.user != nil || unit.service.group != nil ||
            !unit.service.supplementaryGroups.isEmpty || unit.service.umask != nil ||
            unit.service.limitNOFILE != nil
        guard needsHelper else {
            return ("/bin/sh", ["-c", shellScript])
        }

        let helper = ProcessInfo.processInfo.environment["SYSTEMD_MACOS_EXEC_HELPER"]
            ?? "/usr/local/bin/systemd-exec-helper"
        var arguments: [String] = []
        if let user = unit.service.user { arguments += ["--user", user] }
        if let group = unit.service.group { arguments += ["--group", group] }
        if !unit.service.supplementaryGroups.isEmpty {
            arguments += ["--supplementary-groups", unit.service.supplementaryGroups.joined(separator: ",")]
        }
        if let umask = unit.service.umask { arguments += ["--umask", String(format: "%03o", umask)] }
        if let limitNOFILE = unit.service.limitNOFILE { arguments += ["--nofile", String(limitNOFILE)] }
        arguments += ["--command", shellScript]
        return (helper, arguments)
    }

    private func validatePermissionConfiguration(_ unit: UnitFile) throws {
        let capabilities = unit.service.capabilityBoundingSet + unit.service.ambientCapabilities
        if !capabilities.isEmpty {
            throw ManagerError.invalidConfiguration("CapabilityBoundingSet= and AmbientCapabilities= are Linux-only and cannot be enforced on macOS")
        }
        if unit.service.noNewPrivileges {
            throw ManagerError.invalidConfiguration("NoNewPrivileges= has no exact macOS equivalent and cannot be enforced")
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func environment(for unit: UnitFile) -> [String: String] {
        var values = ProcessInfo.processInfo.environment
        for file in unit.service.environmentFiles where file != "" && !file.hasPrefix("-") {
            if let contents = try? String(contentsOfFile: file) {
                for raw in contents.components(separatedBy: .newlines) {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    guard !line.isEmpty, !line.hasPrefix("#"), let index = line.firstIndex(of: "=") else { continue }
                    values[String(line[..<index])] = String(line[line.index(after: index)...])
                }
            }
        }
        for (key, value) in unit.service.environment { values[key] = value }
        return values
    }

    private func logURL(for unit: UnitFile, stream: String) throws -> URL {
        try fileManager.createDirectory(at: SystemdPaths.logDirectory, withIntermediateDirectories: true)
        let url = SystemdPaths.logDirectory.appendingPathComponent("\(unit.name).\(stream).log")
        if !fileManager.fileExists(atPath: url.path) { fileManager.createFile(atPath: url.path, contents: Data()) }
        return url
    }

    private func normalize(_ name: String) -> String {
        name.hasSuffix(".service") ? name : name + ".service"
    }
}
