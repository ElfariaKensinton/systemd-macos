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
    var noPager = false
}

func usage() -> Never {
    print("systemctl [OPTIONS...] COMMAND [UNIT...]")
    print("")
    print("Control the service manager.")
    print("")
    print("Commands:")
    print("  start UNIT...           Start units")
    print("  stop UNIT...            Stop units")
    print("  restart UNIT...         Restart units")
    print("  reload UNIT...          Reload units")
    print("  status UNIT...          Show runtime status")
    print("  enable UNIT...          Enable units")
    print("  disable UNIT...         Disable units")
    print("  is-active UNIT...       Check whether units are active")
    print("  is-enabled UNIT...      Check whether units are enabled")
    print("  daemon-reload           Reload unit files")
    print("  list-units              List loaded units")
    print("  list-unit-files         List installed unit files")
    print("  cat UNIT...             Show unit file contents")
    print("  show UNIT...            Show machine-readable properties")
    print("")
    print("Options:")
    print("  --now                   Enable/disable and immediately start/stop")
    print("  --quiet, -q             Suppress successful output")
    print("  --no-legend             Omit headers")
    print("  --no-pager              Disable the pager")
    print("  --system                Accepted; system scope is the default")
    print("  --user                  Use user unit directory where supported")
    print("  --plain                 Accepted for systemctl compatibility")
    print("  --version               Show version")
    print("  --help, -h              Show this help")
    exit(1)
}

func parseArguments(_ args: [String]) throws -> (CLIOptions, Bool) {
    var tokens = Array(args.dropFirst())
    var quiet = false
    var noLegend = false
    var noPager = false
    var now = false
    var index = 0

    while index < tokens.count {
        let token = tokens[index]
        switch token {
        case "--quiet", "-q":
            quiet = true
            tokens.remove(at: index)
        case "--no-legend", "--system", "--user", "--plain":
            if token == "--no-legend" { noLegend = true }
            tokens.remove(at: index)
        case "--no-pager":
            noPager = true
            tokens.remove(at: index)
        case "--now":
            now = true
            tokens.remove(at: index)
        case "--version":
            print("systemctl 0.1.0")
            exit(0)
        case "--help", "-h": usage()
        default:
            if token.hasPrefix("-") { throw ManagerError.ipc("unknown option \(token)") }
            index += 1
        }
    }

    guard let actionString = tokens.first, let action = SystemctlAction(rawValue: actionString) else { usage() }
    tokens.removeFirst()
    if action != .daemonReload && action != .listUnits && action != .listUnitFiles && tokens.isEmpty { usage() }
    return (CLIOptions(action: action, units: tokens, quiet: quiet, noLegend: noLegend, noPager: noPager), now)
}

func connect() throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw ManagerError.ipc("socket() failed") }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(SystemdPaths.socket.path.utf8) + [0]
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        close(fd)
        throw ManagerError.ipc("socket path is too long")
    }
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
    return try codec.decode(IPCResponse.self, from: responseData)
}

func printStatuses(_ statuses: [UnitStatus], noLegend: Bool) {
    if !noLegend { print("UNIT\tLOAD\tACTIVE\tSUB\tDESCRIPTION") }
    for status in statuses {
        let description = status.description ?? ""
        print("\(status.name)\t\(status.loadState)\t\(status.activeState)\t\(status.subState)\t\(description)")
    }
}

func outputStatus(_ output: String, noPager: Bool) {
    guard !output.isEmpty else { return }

    let environment = ProcessInfo.processInfo.environment
    let pager = environment["SYSTEMD_PAGER"] ?? environment["PAGER"] ?? "less -R"
    let trimmedPager = pager.trimmingCharacters(in: .whitespacesAndNewlines)
    let usePager = !noPager && isatty(STDOUT_FILENO) == 1 && trimmedPager != "cat" && !trimmedPager.isEmpty

    guard usePager else {
        print(output, terminator: output.hasSuffix("\n") ? "" : "\n")
        return
    }

    let command = trimmedPager.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard !command.isEmpty else {
        print(output, terminator: output.hasSuffix("\n") ? "" : "\n")
        return
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = command

    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError

    do {
        try process.run()
        if let data = output.data(using: .utf8) {
            input.fileHandleForWriting.write(data)
        }
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
    } catch {
        print(output, terminator: output.hasSuffix("\n") ? "" : "\n")
    }
}

var quietOnError = false

do {
    let (options, now) = try parseArguments(CommandLine.arguments)
    quietOnError = options.quiet
    let response: IPCResponse

    if now && options.action == .enable {
        let enabled = try request(IPCRequest(action: .enable, units: options.units))
        guard enabled.exitCode == 0 else {
            if !options.quiet, let error = enabled.error { fputs("\(error)\n", stderr) }
            exit(enabled.exitCode)
        }
        response = try request(IPCRequest(action: .start, units: options.units))
    } else if now && options.action == .disable {
        let stopped = try request(IPCRequest(action: .stop, units: options.units))
        guard stopped.exitCode == 0 else {
            if !options.quiet, let error = stopped.error { fputs("\(error)\n", stderr) }
            exit(stopped.exitCode)
        }
        response = try request(IPCRequest(action: .disable, units: options.units))
    } else {
        response = try request(IPCRequest(action: options.action, units: options.units))
    }

    switch options.action {
    case .status:
        if !options.quiet { outputStatus(response.output, noPager: options.noPager) }
    case .listUnits, .listUnitFiles:
        if !options.quiet { printStatuses(response.statuses, noLegend: options.noLegend) }
    case .isActive:
        if !options.quiet, let first = response.statuses.first {
            print(first.activeState == "active" ? "active" : "inactive")
        }
    case .isEnabled:
        if !options.quiet, let first = response.statuses.first {
            print(first.enabled ? "enabled" : "disabled")
        }
    case .cat, .show:
        if !options.quiet, !response.output.isEmpty { print(response.output) }
    case .daemonReload:
        if !options.quiet { print("Reloaded unit files.") }
    default:
        break
    }

    if response.exitCode != 0 {
        if !options.quiet, let error = response.error { fputs("\(error)\n", stderr) }
        exit(response.exitCode)
    }
    exit(0)
} catch {
    if !quietOnError { fputs("systemctl: \(error.localizedDescription)\n", stderr) }
    exit(1)
}
