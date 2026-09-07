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
    var edit = false
    var editFull = false
    var editRuntime = false
    var editForce = false
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
    print("  edit UNIT               Edit unit drop-in")
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
    print("  --full                  Edit the full unit file instead of a drop-in")
    print("  --runtime               Make the edit runtime-only")
    print("  --force                 Create a missing unit when editing")
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
    var editFull = false
    var editRuntime = false
    var editForce = false
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
        case "--full":
            editFull = true
            tokens.remove(at: index)
        case "--runtime":
            editRuntime = true
            tokens.remove(at: index)
        case "--force":
            editForce = true
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

    guard let actionString = tokens.first else { usage() }
    if actionString == "edit" {
        tokens.removeFirst()
        guard tokens.count == 1 else { usage() }
        return (CLIOptions(action: .status, units: tokens, quiet: quiet, noLegend: noLegend, noPager: noPager,
                           plain: plain, edit: true, editFull: editFull, editRuntime: editRuntime, editForce: editForce), now)
    }

    guard let action = SystemctlAction(rawValue: actionString) else { usage() }
    tokens.removeFirst()
    if action != .daemonReload && action != .listUnits && action != .listUnitFiles && tokens.isEmpty { usage() }
    return (CLIOptions(action: action, units: tokens, quiet: quiet, noLegend: noLegend, noPager: noPager, plain: plain), now)
}

func editUnit(_ name: String, full: Bool, runtime: Bool, force: Bool) throws {
    let normalized = name.hasSuffix(".service") ? name : name + ".service"
    let fm = FileManager.default
    let systemPath = SystemdPaths.systemUnitDirectory.appendingPathComponent(normalized)
    let vendorPath = SystemdPaths.vendorUnitDirectory.appendingPathComponent(normalized)
    let baseExists = fm.fileExists(atPath: systemPath.path) || fm.fileExists(atPath: vendorPath.path)

    if !baseExists && !force {
        throw ManagerError.unitNotFound(normalized)
    }

    let target: URL
    do {
        if full {
            target = (runtime ? SystemdPaths.runtimeUnitDirectory : SystemdPaths.systemUnitDirectory).appendingPathComponent(normalized)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: target.path) {
                if let source = [systemPath, vendorPath].first(where: { fm.fileExists(atPath: $0.path) }) {
                    try fm.copyItem(at: source, to: target)
                } else {
                    try "[Unit]\n\n[Service]\nType=simple\nExecStart=\n\n".write(to: target, atomically: true, encoding: .utf8)
                }
            }
        } else {
            let directory = (runtime ? SystemdPaths.runtimeUnitDirectory : SystemdPaths.systemUnitDirectory)
                .appendingPathComponent("\(normalized).d", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            target = directory.appendingPathComponent("override.conf")
            if !fm.fileExists(atPath: target.path) {
                try "[Unit]\n\n[Service]\n\n".write(to: target, atomically: true, encoding: .utf8)
            }
        }
    } catch {
        if String(describing: error).localizedCaseInsensitiveContains("permission denied") {
            throw ManagerError.ipc("permission denied writing unit file — try again with sudo")
        }
        throw error
    }

    let environment = ProcessInfo.processInfo.environment
    let editorSpec = environment["SYSTEMD_EDITOR"] ?? environment["SUDO_EDITOR"] ?? environment["EDITOR"] ?? environment["VISUAL"] ?? "/usr/bin/vi"
    let parts = editorSpec.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard let executable = parts.first else { throw ManagerError.ipc("editor is empty") }

    let execPath: String
    let argv: [String]
    if executable.hasPrefix("/") {
        execPath = executable
        argv = parts + [target.path]
    } else {
        execPath = "/usr/bin/env"
        argv = [execPath] + parts + [target.path]
    }

    var pid: pid_t = 0
    let cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
    let envPairs = environment.map { "\($0.key)=\($0.value)" }
    let cEnv: [UnsafeMutablePointer<CChar>?] = envPairs.map { strdup($0) } + [nil]
    let spawnResult = posix_spawn(&pid, execPath, nil, nil, cArgv, cEnv)
    for ptr in cArgv where ptr != nil { free(ptr) }
    for ptr in cEnv where ptr != nil { free(ptr) }

    guard spawnResult == 0 else {
        throw ManagerError.ipc("failed to launch editor \(executable): \(String(cString: strerror(spawnResult)))")
    }

    var status: Int32 = 0
    waitpid(pid, &status, 0)
    guard WIFEXITED(status) else {
        throw ManagerError.ipc("editor terminated abnormally")
    }
    let terminationStatus = WEXITSTATUS(status)
    guard terminationStatus == 0 else {
        throw ManagerError.ipc("editor exited with status \(terminationStatus)")
    }
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

    var command = pagerSpec.isEmpty ? ["/usr/bin/less", "-R"] : pagerSpec.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    if command.first?.hasSuffix("less") == true {
        command.removeAll { $0 == "-S" || $0 == "--chop-long-lines" || $0 == "-X" || $0 == "--no-init" }
        if command.count == 1 { command.append("-R") }
    }

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

    if options.edit {
        do {
            try editUnit(options.units[0], full: options.editFull, runtime: options.editRuntime, force: options.editForce)
            let reloaded = try request(IPCRequest(action: .daemonReload, units: []))
            if reloaded.exitCode != 0 {
                if !options.quiet, let error = reloaded.error { fputs("\(error)\n", stderr) }
                exit(reloaded.exitCode)
            }
            if !options.quiet { print("Editing \(options.units[0].hasSuffix(".service") ? options.units[0] : options.units[0] + ".service")") }
            exit(0)
        } catch {
            if !options.quiet { fputs("systemctl: \(error)\n", stderr) }
            exit(1)
        }
    }

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
