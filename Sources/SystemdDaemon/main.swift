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
        let input = FileHandle(fileDescriptor: client, closeOnDealloc: false).readDataToEndOfFile()
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
            return try perform(request.units) { try manager.start($0) }
        case .stop:
            return try perform(request.units) { try manager.stop($0) }
        case .restart:
            return try perform(request.units) { try manager.restart($0) }
        case .reload:
            return try perform(request.units) { try manager.restart($0) }
        case .enable:
            return try perform(request.units) { try manager.enable($0) }
        case .disable:
            return try perform(request.units) { try manager.disable($0) }
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
                dictionary.keys.sorted().map { "\($0)=\(dictionary[$0] ?? "")" }.joined(separator: "\n")
            }.joined(separator: "\n")
            return IPCResponse(exitCode: 0, output: output)
        }
    }

    private func perform(_ units: [String], _ action: (String) throws -> Void) throws -> IPCResponse {
        guard !units.isEmpty else { throw ManagerError.ipc("No unit name specified.") }
        for unit in units { try action(unit) }
        return IPCResponse(exitCode: 0)
    }

    private func render(_ statuses: [UnitStatus]) -> String {
        var blocks: [String] = []
        for status in statuses {
            let marker = status.activeState == "active" ? "●" : "○"
            let description = status.description ?? ""
            let stateText: String
            switch status.subState {
            case "active": stateText = "active (running)"
            case "activating": stateText = "activating (start)"
            case "exited": stateText = "inactive (exited)"
            default: stateText = "inactive (dead)"
            }

            var lines: [String] = []
            lines.append("\(marker) \(status.name) - \(description)")
            let enabledText = status.enabled ? "enabled" : "disabled"
            let path = status.path ?? "/etc/systemd/system/\(status.name)"
            lines.append("     Loaded: loaded (\(path); \(enabledText))")
            lines.append("     Active: \(stateText) (\(status.result))")
            if status.mainPID != 0 {
                lines.append("   Main PID: \(status.mainPID)")
            }
            lines.append("        Docs: systemd-macos")

            let stdoutURL = SystemdPaths.logDirectory.appendingPathComponent("\(status.name).stdout.log")
            let stderrURL = SystemdPaths.logDirectory.appendingPathComponent("\(status.name).stderr.log")
            let stdout = tail(url: stdoutURL, lines: 10)
            let stderr = tail(url: stderrURL, lines: 10)
            if !stdout.isEmpty || !stderr.isEmpty {
                lines.append("")
                lines.append("Sep 06 00:00:00 systemd-macos \(status.name)[\(status.mainPID)]: Journal output")
                for line in stdout + stderr {
                    lines.append("Sep 06 00:00:00 systemd-macos \(status.name)[\(status.mainPID)]: \(line)")
                }
            }
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    private func tail(url: URL, lines: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(whereSeparator: { $0.isNewline }, omittingEmptySubsequences: true).suffix(lines)).map(String.init)
    }
}

let manager = ServiceManager()
let server = UnixServer(manager: manager)
do {
    try server.run()
} catch {
    fputs("systemd: \(error.localizedDescription)\n", stderr)
    exit(1)
}
