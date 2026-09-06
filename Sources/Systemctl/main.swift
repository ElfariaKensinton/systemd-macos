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
    var plain = false
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
    print("  --plain                 Disable ANSI colors and underlines")
    print("  --version               Show version")
    print("  --help, -h              Show this help")
    exit(1)
}

func parseArguments(_ args: [String]) throws -> (CLIOptions, Bool) {
    var tokens = Array(args.dropFirst())
    var quiet = false
    var noLegend = false
    var noPager = false
    var plain = false
    var now = false
    var index = 0

    while index < tokens.count {
        let token = tokens[index]
        switch token {
        case "--quiet", "-q":
            quiet = true
            tokens.remove(at: index)
        case "--no-legend", "--system", "--user":
            if token == "--no-legend" { noLegend = true }
            tokens.remove(at: index)
        case "--plain":
            plain = true
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
    return (CLIOptions(action: action, units: tokens, quiet: quiet, noLegend: noLegend, noPager: noPager, plain: plain), now)
}

func connect() throws -> Int32 {
    var lastError = "is the daemon running?"

    for attempt in 0..<20 {
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
        if result == 0 { return fd }

        lastError = "cannot connect to systemd at \(SystemdPaths.socket.path); \(String(cString: strerror(errno)))"
        close(fd)
        if attempt < 19 { usleep(50_000) }
    }

    throw ManagerError.ipc("\(lastError)")
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

func outputStatus(_ output: String, noPager: Bool, plain: Bool, statuses: [UnitStatus]) {
    guard !output.isEmpty else { return }
    let formatted = colorizedStatusOutput(output, statuses: statuses, plain: plain)

    let environment = ProcessInfo.processInfo.environment
    let pagerSpec = (environment["SYSTEMD_PAGER"] ?? environment["PAGER"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

    if noPager || pagerSpec == "cat" || isatty(STDOUT_FILENO) != 1 || isatty(STDIN_FILENO) != 1 {
        print(formatted, terminator: formatted.hasSuffix("\n") ? "" : "\n")
        return
    }

    let command = pagerSpec.isEmpty ? ["/usr/bin/less", "-FRSX"] : pagerSpec.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard let executable = command.first else {
        print(formatted, terminator: formatted.hasSuffix("\n") ? "" : "\n")
        return
    }

    var pipeFDs: [Int32] = [0, 0]
    guard pipeFDs.withUnsafeMutableBufferPointer({ pipe($0.baseAddress) }) == 0 else {
        print(formatted, terminator: formatted.hasSuffix("\n") ? "" : "\n")
        return
    }
    let readFD = pipeFDs[0]
    let writeFD = pipeFDs[1]

    let execPath: String
    let argv: [String]
    if executable.hasPrefix("/") {
        execPath = executable
        argv = command
    } else {
        execPath = "/usr/bin/env"
        argv = [execPath] + command
    }

    var pid: pid_t = 0
    let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    let environmentPairs = environment.map { "\($0.key)=\($0.value)" }
    let cEnv: [UnsafeMutablePointer<CChar>?] = environmentPairs.map { strdup($0) } + [nil]

    let fileActionsPtr = UnsafeMutablePointer<posix_spawn_file_actions_t?>.allocate(capacity: 1)
    defer { fileActionsPtr.deallocate() }
    posix_spawn_file_actions_init(fileActionsPtr)
    posix_spawn_file_actions_adddup2(fileActionsPtr, readFD, 0)
    posix_spawn_file_actions_addclose(fileActionsPtr, readFD)
    posix_spawn_file_actions_addclose(fileActionsPtr, writeFD)

    let spawnResult = posix_spawn(&pid, execPath, fileActionsPtr, nil, cArgv, cEnv)
    posix_spawn_file_actions_destroy(fileActionsPtr)
    for ptr in cArgv where ptr != nil { free(ptr) }
    for ptr in cEnv where ptr != nil { free(ptr) }

    close(readFD)
    guard spawnResult == 0 else {
        close(writeFD)
        print(formatted, terminator: formatted.hasSuffix("\n") ? "" : "\n")
        return
    }

    let bytes = Array(formatted.utf8)
    var offset = 0
    bytes.withUnsafeBufferPointer { buffer in
        while offset < buffer.count {
            let n = write(writeFD, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if n <= 0 { break }
            offset += n
        }
    }
    close(writeFD)

    var status: Int32 = 0
    waitpid(pid, &status, 0)
}

var quietOnError = false

do {
    let (options, now) = try parseArguments(CommandLine.arguments)
    quietOnError = options.quiet

    if now && options.action == .enable {
        let enabled = try request(IPCRequest(action: .enable, units: options.units))
        guard enabled.exitCode == 0 else {
            if !options.quiet, let error = enabled.error { fputs("\(error)\n", stderr) }
            exit(enabled.exitCode)
        }
        if !options.quiet, !enabled.output.isEmpty { print(enabled.output) }

        let started = try request(IPCRequest(action: .start, units: options.units))
        if started.exitCode != 0 {
            if !options.quiet, let error = started.error { fputs("\(error)\n", stderr) }
            exit(started.exitCode)
        }
        exit(0)
    }

    if now && options.action == .disable {
        let stopped = try request(IPCRequest(action: .stop, units: options.units))
        guard stopped.exitCode == 0 else {
            if !options.quiet, let error = stopped.error { fputs("\(error)\n", stderr) }
            exit(stopped.exitCode)
        }

        let disabled = try request(IPCRequest(action: .disable, units: options.units))
        guard disabled.exitCode == 0 else {
            if !options.quiet, let error = disabled.error { fputs("\(error)\n", stderr) }
            exit(disabled.exitCode)
        }
        if !options.quiet, !disabled.output.isEmpty { print(disabled.output) }
        exit(0)
    }

    let response = try request(IPCRequest(action: options.action, units: options.units))

    switch options.action {
    case .status:
        if !options.quiet { outputStatus(response.output, noPager: options.noPager, plain: options.plain, statuses: response.statuses) }
    case .listUnits, .listUnitFiles:
        if !options.quiet { printStatuses(response.statuses, noLegend: options.noLegend) }
    case .isActive:
        if !options.quiet, let first = response.statuses.first { print(first.activeState == "active" ? "active" : "inactive") }
    case .isEnabled:
        if !options.quiet, let first = response.statuses.first { print(first.enabled ? "enabled" : "disabled") }
    case .cat, .show, .enable, .disable:
        if !options.quiet, !response.output.isEmpty { print(response.output) }
    case .daemonReload:
        break
    default:
        break
    }

    if response.exitCode != 0 {
        if !options.quiet, let error = response.error { fputs("\(error)\n", stderr) }
        exit(response.exitCode)
    }
    exit(0)
} catch {
    if !quietOnError { fputs("systemctl: \(error)\n", stderr) }
    exit(1)
}
