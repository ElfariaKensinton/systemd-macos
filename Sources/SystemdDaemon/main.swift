import Foundation
import SystemdCore
#if canImport(Darwin)
import Darwin
#endif

final class UnixServer {
    private let manager: ServiceManager
    private let codec = LineCodec()
    private let parser = UnitParser()
    private var socketFD: Int32 = -1

    init(manager: ServiceManager) { self.manager = manager }

    func run() throws -> Never {
        try FileManager.default.createDirectory(at: SystemdPaths.stateDirectory, withIntermediateDirectories: true)
        unlink(SystemdPaths.socket.path)

        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw ManagerError.ipc("Failed to create IPC socket: \(String(cString: strerror(errno)))") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(SystemdPaths.socket.path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw ManagerError.ipc("IPC socket path is too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { throw ManagerError.ipc("Failed to bind IPC socket: \(String(cString: strerror(errno)))") }

        // Pin ownership to root:wheel explicitly rather than trusting
        // whatever group the daemon's process happens to be running under
        // at bind time — that's an OS/launchd implementation detail, not a
        // guarantee. wheel is macOS's traditional "trusted admin" group.
        if let wheelGroup = getgrnam("wheel") {
            chown(SystemdPaths.socket.path, 0, wheelGroup.pointee.gr_gid)
        }
        chmod(SystemdPaths.socket.path, 0o660)
        guard listen(socketFD, 16) == 0 else { throw ManagerError.ipc("Failed to listen on IPC socket: \(String(cString: strerror(errno)))") }

        manager.startEnabledUnits()

        while true {
            let client = accept(socketFD, nil, nil)
            if client < 0 { continue }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(client: client)
            }
        }
    }

    // File permissions on the socket are a first filter, but they aren't
    // sufficient authorization by themselves for a channel that can issue
    // root-level start/stop/enable commands — anyone who can reach the
    // socket (e.g. through a future permission mistake, a misconfigured
    // group, or a bind-mount) would otherwise be able to drive the daemon
    // with zero additional identity check. Verify the actual connecting
    // process's credentials before dispatching anything it sends.
    private func isAuthorized(client: Int32) -> Bool {
        var credential = xucred()
        var size = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERCRED, &credential, &size) == 0 else {
            return false
        }
        if credential.cr_uid == 0 { return true }
        guard let wheelGroup = getgrnam("wheel") else { return false }
        let wheelGID = wheelGroup.pointee.gr_gid
        let groupCount = Int(credential.cr_ngroups)
        return withUnsafeBytes(of: credential.cr_groups) { raw -> Bool in
            let groups = raw.bindMemory(to: gid_t.self)
            for index in 0..<min(groupCount, groups.count) where groups[index] == wheelGID {
                return true
            }
            return false
        }
    }

    private func handle(client: Int32) {
        defer { close(client) }

        guard isAuthorized(client: client) else {
            let response = IPCResponse(exitCode: 1, error: "Permission denied: only root or members of the admin (wheel) group may control units.")
            if let data = try? codec.encode(response) {
                _ = data.withUnsafeBytes { send(client, $0.baseAddress, data.count, 0) }
            }
            return
        }

        let handle = FileHandle(fileDescriptor: client, closeOnDealloc: false)
        var input = Data()
        while input.firstIndex(of: 0x0A) == nil {
            let chunk = handle.readData(ofLength: 4096)
            if chunk.isEmpty { return }
            input.append(chunk)
        }

        guard let newline = input.firstIndex(of: 0x0A) else { return }
        let requestData = input[..<newline]
        do {
            let request = try codec.decode(IPCRequest.self, from: requestData)
            let response = try dispatch(request)
            let data = try codec.encode(response)
            _ = data.withUnsafeBytes { send(client, $0.baseAddress, data.count, 0) }
        } catch {
            let response = IPCResponse(exitCode: 1, error: error.localizedDescription)
            if let data = try? codec.encode(response) {
                _ = data.withUnsafeBytes { send(client, $0.baseAddress, data.count, 0) }
            }
        }
    }

    private func dispatch(_ request: IPCRequest) throws -> IPCResponse {
        switch request.action {
        case .daemonReload:
            manager.load()
            return IPCResponse(exitCode: 0)
        case .listUnits:
            return IPCResponse(exitCode: 0, statuses: manager.listUnits())
        case .listUnitFiles:
            return IPCResponse(exitCode: 0, statuses: manager.listUnitFiles())
        case .start:
            return perform(request.units, actionName: "start") { try manager.start($0) }
        case .stop:
            return perform(request.units, actionName: "stop") { try manager.stop($0) }
        case .restart:
            return perform(request.units, actionName: "restart") { try manager.restart($0) }
        case .reload:
            return perform(request.units, actionName: "reload") { try manager.restart($0) }
        case .enable:
            return performWithOutput(request.units, actionName: "enable") { unit in
                let before = try manager.status(unit)
                try manager.enable(unit)
                let after = try manager.status(unit)
                guard !before.enabled && after.enabled else { return [] }
                let marker = SystemdPaths.enablementDirectory.appendingPathComponent(after.name)
                let target = after.path ?? "/etc/systemd/system/\(after.name)"
                return ["Created symlink: \(marker.path) → \(target)"]
            }
        case .disable:
            return performWithOutput(request.units, actionName: "disable") { unit in
                let before = try manager.status(unit)
                try manager.disable(unit)
                let after = try manager.status(unit)
                guard before.enabled && !after.enabled else { return [] }
                let marker = SystemdPaths.enablementDirectory.appendingPathComponent(after.name)
                return ["Removed \(marker.path)"]
            }
        case .status:
            let statuses = try request.units.map(manager.status)
            let output = render(statuses)
            let active = statuses.allSatisfy { $0.activeState == "active" }
            return IPCResponse(exitCode: active ? 0 : 3, output: output, statuses: statuses)
        case .isActive:
            let statuses = try request.units.map(manager.status)
            let active = statuses.allSatisfy { $0.activeState == "active" }
            return IPCResponse(exitCode: active ? 0 : 3, statuses: statuses)
        case .isEnabled:
            let statuses = try request.units.map(manager.status)
            let enabled = statuses.allSatisfy { $0.enabled }
            return IPCResponse(exitCode: enabled ? 0 : 1, statuses: statuses)
        case .cat:
            return IPCResponse(exitCode: 0, output: try request.units.map(manager.cat).joined(separator: "\n"))
        case .show:
            let values = try request.units.map { try manager.show($0) }
            let output = values.map { dictionary in
                dictionary.keys.sorted().map { key in
                    "\(key)=\(dictionary[key] ?? "")"
                }.joined(separator: "\n")
            }.joined(separator: "\n")
            return IPCResponse(exitCode: 0, output: output)
        }
    }

    private func perform(_ units: [String], actionName: String, _ action: (String) throws -> Void) -> IPCResponse {
        guard !units.isEmpty else {
            return IPCResponse(exitCode: 1, error: "No unit name specified.")
        }

        for unit in units {
            do {
                try action(unit)
            } catch ManagerError.commandFailed {
                return IPCResponse(
                    exitCode: 1,
                    error: "Job for \(unit) failed because the control process exited with error code.\nSee \"systemctl status \(unit)\" and \"journalctl -xeu \(unit)\" for details."
                )
            } catch ManagerError.unitNotFound {
                return IPCResponse(
                    exitCode: 5,
                    error: "Failed to \(actionName) \(unit): Unit \(unit) not found."
                )
            } catch {
                return IPCResponse(
                    exitCode: 1,
                    error: "Failed to \(actionName) \(unit): \(error.localizedDescription)"
                )
            }
        }
        return IPCResponse(exitCode: 0)
    }

    private func performWithOutput(_ units: [String], actionName: String, _ action: (String) throws -> [String]) -> IPCResponse {
        guard !units.isEmpty else {
            return IPCResponse(exitCode: 1, error: "No unit name specified.")
        }

        var operations: [String] = []
        for unit in units {
            do {
                operations += try action(unit)
            } catch ManagerError.commandFailed {
                return IPCResponse(
                    exitCode: 1,
                    error: "Job for \(unit) failed because the control process exited with error code.\nSee \"systemctl status \(unit)\" and \"journalctl -xeu \(unit)\" for details."
                )
            } catch ManagerError.unitNotFound {
                return IPCResponse(
                    exitCode: 5,
                    error: "Failed to \(actionName) \(unit): Unit \(unit) not found."
                )
            } catch {
                return IPCResponse(
                    exitCode: 1,
                    error: "Failed to \(actionName) \(unit): \(error.localizedDescription)"
                )
            }
        }
        return IPCResponse(exitCode: 0, output: operations.joined(separator: "\n"))
    }

    private func render(_ statuses: [UnitStatus]) -> String {
        var blocks: [String] = []
        let stampFormatter = DateFormatter()
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.dateFormat = "MMM dd HH:mm:ss"

        let sinceFormatter = DateFormatter()
        sinceFormatter.locale = Locale(identifier: "en_US_POSIX")
        sinceFormatter.dateFormat = "EEE yyyy-MM-dd HH:mm:ss"

        for status in statuses {
            let marker = status.activeState == "active" ? "●" : "○"
            let stateText: String
            switch status.subState {
            case "active": stateText = "active (running)"
            case "activating": stateText = "activating (start)"
            case "exited": stateText = "inactive (exited)"
            default: stateText = "inactive (dead)"
            }

            let unit = status.path.flatMap { try? parser.parse(url: URL(fileURLWithPath: $0)) }
            var lines: [String] = []

            if let description = status.description, !description.isEmpty {
                lines.append("\(marker) \(status.name) - \(description)")
            } else {
                lines.append("\(marker) \(status.name)")
            }

            let enabledText = status.enabled ? "enabled" : "disabled"
            let path = status.path ?? "/etc/systemd/system/\(status.name)"
            lines.append("     Loaded: loaded (\(path); \(enabledText))")

            var activeLine = "     Active: \(stateText)"
            if status.activeState == "active", let since = status.activeSince {
                activeLine += " since \(sinceFormatter.string(from: since)); \(relativeDuration(from: since))"
            } else if status.result != "success" {
                activeLine += " (Result: \(status.result))"
            }
            lines.append(activeLine)

            if let trigger = socketTrigger(for: status) {
                lines.append("TriggeredBy: ● \(trigger)")
            }

            if let documentation = unit?.documentation {
                for item in documentation where !item.isEmpty {
                    lines.append("     Docs: \(item)")
                }
            }

            if let startPre = unit?.service.execStartPre {
                for command in startPre where !command.isEmpty {
                    lines.append("    Process: \(status.mainPID == 0 ? 0 : status.mainPID) ExecStartPre=\(command) (code=exited, status=0/SUCCESS)")
                }
            }

            if status.mainPID != 0 {
                lines.append("   Main PID: \(status.mainPID) (\(processName(status.mainPID) ?? "unknown"))")
                let metrics = processMetrics(status.mainPID)
                lines.append("      Tasks: \(metrics.tasks)")
                lines.append("     Memory: \(formatMemory(kilobytes: metrics.rssKB))")
                lines.append("        CPU: \(metrics.cpuTime)")
                lines.append("     CGroup: /system.slice/\(status.name)")
                if let command = processCommand(status.mainPID) {
                    lines.append("         └─\(status.mainPID) \"\(command)\"")
                }
            }

            let stdoutURL = SystemdPaths.logDirectory.appendingPathComponent("\(status.name).stdout.log")
            let stderrURL = SystemdPaths.logDirectory.appendingPathComponent("\(status.name).stderr.log")
            let stdout = tail(url: stdoutURL, lines: 10)
            let stderr = tail(url: stderrURL, lines: 10)
            if !stdout.isEmpty || !stderr.isEmpty {
                let stdoutStamp = stampFormatter.string(from: modificationDate(of: stdoutURL))
                let stderrStamp = stampFormatter.string(from: modificationDate(of: stderrURL))
                let pid = status.mainPID
                lines.append("")
                for line in stdout {
                    lines.append("\(stdoutStamp) \(status.name)[\(pid)]: \(sanitizeJournalLine(line))")
                }
                for line in stderr {
                    lines.append("\(stderrStamp) \(status.name)[\(pid)]: \(sanitizeJournalLine(line))")
                }
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    private func socketTrigger(for status: UnitStatus) -> String? {
        let base = status.name.hasSuffix(".service") ? String(status.name.dropLast(".service".count)) : status.name
        let candidate = "\(base).socket"
        guard let directory = status.path.map({ URL(fileURLWithPath: $0).deletingLastPathComponent() }) else { return nil }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) ? candidate : nil
    }

    private func runPS(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private func processName(_ pid: Int32) -> String? {
        guard let value = runPS(["-p", String(pid), "-o", "comm="]), !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value).lastPathComponent
    }

    private func processCommand(_ pid: Int32) -> String? {
        guard let value = runPS(["-p", String(pid), "-o", "command="]), !value.isEmpty else { return nil }
        return value
    }

    private func processMetrics(_ pid: Int32) -> (tasks: Int, rssKB: Int64, cpuTime: String) {
        var tasks = 1
        if let threadOutput = runPS(["-M", "-p", String(pid), "-o", "tid="]) {
            let count = threadOutput.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
            if count > 0 { tasks = count }
        }

        var rssKB: Int64 = 0
        var cpuTime = "0s"
        if let metricOutput = runPS(["-p", String(pid), "-o", "rss=,time="]) {
            let pieces = metricOutput.split(whereSeparator: { $0.isWhitespace })
            if let first = pieces.first { rssKB = Int64(first) ?? 0 }
            if pieces.count > 1 { cpuTime = pieces.dropFirst().joined(separator: " ") }
        }
        return (tasks, rssKB, cpuTime)
    }

    private func formatMemory(kilobytes: Int64) -> String {
        if kilobytes < 1024 { return "\(kilobytes)K" }
        let megabytes = Double(kilobytes) / 1024.0
        if megabytes < 1024 { return String(format: "%.1fM", megabytes) }
        return String(format: "%.1fG", megabytes / 1024.0)
    }

    private func relativeDuration(from date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)min \(seconds % 60)s ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)min ago" }
        let days = hours / 24
        return "\(days) day\(days == 1 ? "" : "s") ago"
    }

    private func modificationDate(of url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? Date()
    }

    private func sanitizeJournalLine(_ line: String) -> String {
        var value = line
        if value.hasPrefix("/bin/sh: ") {
            value.removeFirst("/bin/sh: ".count)
        }
        return value
    }

    private func tail(url: URL, lines: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline }).suffix(lines)).map(String.init)
    }
}

let manager = ServiceManager()
let server = UnixServer(manager: manager)
do {
    try server.run()
} catch {
    fputs("Failed to start service manager: \(error.localizedDescription)\n", stderr)
    exit(1)
}
