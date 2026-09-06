import Foundation
import SystemdCore
#if canImport(Darwin)
import Darwin
#endif

final class UnixServer {
    private let manager: ServiceManager
    private let codec = LineCodec()
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

    private func handle(client: Int32) {
        defer { close(client) }

        // IPC is newline-framed. Do not wait for EOF: a client may keep the
        // connection open while waiting for the response.
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
            return perform(request.units, actionName: "enable") { try manager.enable($0) }
        case .disable:
            return perform(request.units, actionName: "disable") { try manager.disable($0) }
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

            var lines: [String] = []
            if let description = status.description, !description.isEmpty {
                lines.append("\(marker) \(status.name) - \(description)")
            } else {
                lines.append("\(marker) \(status.name)")
            }
            let enabledText = status.enabled ? "enabled" : "disabled"
            let path = status.path ?? "/etc/systemd/system/\(status.name)"
            lines.append("     Loaded: loaded (\(path); \(enabledText))")

            // Real systemd only appends a (result) qualifier for terminal
            // states where the result is meaningful (e.g. "failed" units
            // show "(Result: exit-code)"). Printing "(success)" next to
            // "inactive (dead)" for a unit that was simply never started is
            // misleading — a plain "inactive (dead)" line, or one that
            // reports the actual failure, matches what systemd shows.
            var activeLine = "     Active: \(stateText)"
            if status.activeState == "active", let since = status.activeSince {
                activeLine += " since \(sinceFormatter.string(from: since)); \(relativeDuration(from: since))"
            } else if status.result != "success" {
                activeLine += " (Result: \(status.result))"
            }
            lines.append(activeLine)

            if status.mainPID != 0 {
                lines.append("   Main PID: \(status.mainPID)")
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
