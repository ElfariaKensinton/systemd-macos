import Foundation
import Darwin

struct Arguments {
    var user: String?
    var group: String?
    var supplementaryGroups: [String]
    var umask: mode_t?
    var nofile: rlim_t?
    var command: String
}

@inline(__always)
func fail(_ message: String, code: Int32 = 1) -> Never {
    fputs("systemd-exec-helper: \(message)\n", stderr)
    exit(code)
}

func lookupUser(_ name: String) -> passwd {
    var entry = passwd()
    guard let pointer = getpwnam_r(name, &entry, nil, 0, nil), pointer != nil else {
        fail("user \(name) not found")
    }
    return entry
}

func lookupGroup(_ name: String) -> gid_t {
    var entry = group()
    let bufferSize = 16_384
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    var result: UnsafeMutablePointer<group>?
    let rc = getgrnam_r(name, &entry, buffer, bufferSize, &result)
    guard rc == 0, result != nil else { fail("group \(name) not found") }
    return entry.gr_gid
}

func parseOctalMode(_ value: String) -> mode_t {
    guard let parsed = UInt32(value, radix: 8), parsed <= 0o7777 else {
        fail("invalid UMask=\(value)")
    }
    return mode_t(parsed)
}

func parseLimit(_ value: String) -> rlim_t {
    guard let parsed = UInt64(value) else { fail("invalid LimitNOFILE=\(value)") }
    return rlim_t(parsed)
}

func parseArguments() -> Arguments {
    var user: String?
    var group: String?
    var supplementary: [String] = []
    var umask: mode_t?
    var nofile: rlim_t?
    var command: String?

    var index = 1
    let args = CommandLine.arguments
    while index < args.count {
        switch args[index] {
        case "--user":
            index += 1; guard index < args.count else { fail("--user requires a value") }
            user = args[index]
        case "--group":
            index += 1; guard index < args.count else { fail("--group requires a value") }
            group = args[index]
        case "--supplementary-groups":
            index += 1; guard index < args.count else { fail("--supplementary-groups requires a value") }
            supplementary = args[index].split(separator: ",", omittingEmptySubsequences: true).map(String.init)
        case "--umask":
            index += 1; guard index < args.count else { fail("--umask requires a value") }
            umask = parseOctalMode(args[index])
        case "--nofile":
            index += 1; guard index < args.count else { fail("--nofile requires a value") }
            nofile = parseLimit(args[index])
        case "--command":
            index += 1; guard index < args.count else { fail("--command requires a value") }
            command = args[index]
        default:
            fail("unknown argument \(args[index])")
        }
        index += 1
    }

    guard let command else { fail("--command is required") }
    return Arguments(user: user, group: group, supplementaryGroups: supplementary,
                     umask: umask, nofile: nofile, command: command)
}

let arguments = parseArguments()

guard getuid() == 0 else {
    fail("privilege-changing execution requires root", code: 77)
}

var targetUID: uid_t = 0
var targetGID: gid_t = 0
var targetUser: String?

if let user = arguments.user {
    let entry = lookupUser(user)
    targetUID = entry.pw_uid
    targetGID = entry.pw_gid
    targetUser = user
}

if let group = arguments.group {
    targetGID = lookupGroup(group)
}

if let nofile = arguments.nofile {
    var limit = rlimit(rlim_cur: nofile, rlim_max: nofile)
    guard setrlimit(RLIMIT_NOFILE, &limit) == 0 else {
        fail("setrlimit(RLIMIT_NOFILE) failed: \(String(cString: strerror(errno)))")
    }
}

if let umask = arguments.umask {
    _ = Foundation.umask(umask)
}

if !arguments.supplementaryGroups.isEmpty {
    var groups = arguments.supplementaryGroups.map { lookupGroup($0) }
    let rc = groups.withUnsafeMutableBufferPointer { buffer in
        setgroups(buffer.count, buffer.baseAddress)
    }
    guard rc == 0 else {
        fail("setgroups failed: \(String(cString: strerror(errno)))")
    }
} else if let targetUser {
    guard initgroups(targetUser, targetGID) == 0 else {
        fail("initgroups failed for \(targetUser): \(String(cString: strerror(errno)))")
    }
}

if arguments.user != nil || arguments.group != nil {
    guard setgid(targetGID) == 0 else {
        fail("setgid failed: \(String(cString: strerror(errno)))")
    }
    guard setuid(targetUID) == 0 else {
        fail("setuid failed: \(String(cString: strerror(errno)))")
    }
}

execl("/bin/sh", "sh", "-c", arguments.command, nil)
fprintf(stderr, "systemd-exec-helper: exec failed: %s\n", strerror(errno))
exit(126)
