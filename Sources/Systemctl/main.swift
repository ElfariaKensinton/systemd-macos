import Foundation
import SystemdCore
#if canImport(Darwin)
import Darwin
#endif

struct CLIOptions {
    var action: SystemctlAction
    var units: [String]
    var quiet = false
    var noLegend = false
}

func usage() -> Never {
    print("systemctl [OPTIONS...] COMMAND [UNIT...]")
    print("")
    print("Control the systemd-macos service manager.")
    print("")
    print("Commands:")
    print("  start UNIT...          Start units")
    print("  stop UNIT...           Stop units")
    print("  restart UNIT...        Restart units")
    print("  status UNIT...         Show runtime status")
    print("  enable UNIT...         Enable units for boot")
    print("  disable UNIT...        Disable units for boot")
    print("  is-active UNIT...      Check whether units are active")
    print("  is-enabled UNIT...     Check whether units are enabled")
    print("  daemon-reload          Reload unit files")
    print("  list-units             List loaded units")
    print("  list-unit-files        List installed unit files")
    print("  cat UNIT...            Show unit file contents")
    print("  show UNIT...            Show machine-readable properties")
    print("")
    print("Options:")
    print("  --now                  Enable/disable and immediately start/stop")
    print("  --quiet, -q            Suppress successful output")
    print("  --no-legend            Omit headers")
    print("  --no-pager              Accepted for systemctl compatibility")
    print("  --system                Accepted; system scope is the default")
    print("  --user                  Use user unit directory where supported")
    exit(1)
}

func parseArguments(_ args: [String]) throws -> (CLIOptions, Bool) {
    var remaining = Array(args.dropFirst())
    var quiet = false
    var noLegend = false
    var now = false
    var index = 0

    while index < remaining.count, remaining[index].hasPrefix("-") {
        switch remaining[index] {
        case "--quiet", "-q": quiet = true
        case "--no-legend": noLegend = true
        case "--no-pager", "--system", "--user", "--plain": break
        case "--now": now = true
        case "--version": print("systemd-macos 0.1.0"); exit(0)
        case "--help", "-h": usage()
        default: throw ManagerError.ipc("unknown option \(remaining[index])")
        }
        remaining.remove(at: index)
    }

    guard let actionString = remaining.first, let action = SystemctlAction(rawValue: actionString) else { usage() }
    remaining.removeFirst()
    if action != .daemonReload && action != .listUnits && action != .listUnitFiles && remaining.isEmpty { usage() }
    return (CLIOptions(action: action, units: remaining, quiet: quiet, noLegend: noLegend), now)
}

func connect() throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ManagerError.ipc("socket() failed") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(SystemdPaths.socket.path.utf8) + [0]
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.copyBytes(from: pathBytes)
    }
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        close(fd)
        throw ManagerError.ipc("cannot connect to systemd at \(SystemdPaths.socket.path); is the daemon running?")
    }
    return fd
}

func request(_ request: IPCRequest) throws -> IPCResponse {
    let fd = try connect()
    defer { close(fd) }
    let codec = LineCodec()
    let payload = try codec.encode(request)
    _ = payload.withUnsafeBytes { send(fd, $0.baseAddress, payload.count, 0) }
    shutdown(fd, SHUT_WR)
    let responseData = FileHandle(fileDescriptor: fd, closeOnDealloc: false).readDataToEndOfFile()
    return try codec.decode(IPCResponse.self, from: responseData.trimmingCharacters(in: .whitespacesAndNewlines))
}

func printStatuses(_ statuses: [UnitStatus], noLegend: Bool) {
    if !noLegend { print("UNIT\tLOAD\tACTIVE\tSUB\tDESCRIPTION") }
    for status in statuses {
        print("\(status.name)\t\(status.loadState)\t\(status.activeState)\t\(status.subState)\t\(status.description ?? "")")
    }
}

do {
    let (options, now) = try parseArguments(CommandLine.arguments)
    var action = options.action
    var response: IPCResponse

    if now && action == .enable {
        response = try request(IPCRequest(action: .enable, units: options.units))
        guard response.exitCode == 0 else { throw ManagerError.ipc(response.error ?? "enable failed") }
        response = try request(IPCRequest(action: .start, units: options.units))
    } else if now && action == .disable {
        response = try request(IPCRequest(action: .stop, units: options.units))
        guard response.exitCode == 0 else { throw ManagerError.ipc(response.error ?? "stop failed") }
        response = try request(IPCRequest(action: .disable, units: options.units))
    } else {
        action = options.action
        response = try request(IPCRequest(action: action, units: options.units))
    }

    if response.exitCode != 0 {
        if !options.quiet, let error = response.error { fputs("systemctl: \(error)\n", stderr) }
        exit(response.exitCode)
    }

    if !options.quiet {
        switch action {
        case .status: print(response.output)
        case .listUnits, .listUnitFiles: printStatuses(response.statuses, noLegend: options.noLegend)
        case .isActive, .isEnabled: if let first = response.statuses.first { print(first.activeState == "active" || first.enabled ? "active" : "inactive") }
        case .cat, .show: if !response.output.isEmpty { print(response.output) }
        case .daemonReload: print("Reloaded systemd-macos unit files.")
        default: break
        }
    }
    exit(0)
} catch {
    if !options.quiet { fputs("systemctl: \(error.localizedDescription)\n", stderr) }
    exit(1)
}
