import Foundation
import SystemdCore

struct Options {
    var units: [String] = []
    var follow = false
    var lines = 10
}

func usage() -> Never {
    print("journalctl [OPTIONS...]")
    print("Query and follow systemd-macos service logs.")
    print("")
    print("  -u, --unit UNIT    Show logs for a unit")
    print("  -f, --follow       Follow new log output")
    print("  -n, --lines N      Show last N lines")
    print("      --no-pager     Accepted for compatibility")
    print("  -h, --help         Show this help")
    exit(0)
}

func parse(_ args: [String]) -> Options {
    var o = Options()
    var i = 1
    while i < args.count {
        switch args[i] {
        case "-f", "--follow": o.follow = true; i += 1
        case "--no-pager": i += 1
        case "-u", "--unit":
            guard i + 1 < args.count else { fputs("journalctl: --unit requires a unit name\n", stderr); exit(1) }
            let name = args[i + 1]
            o.units.append(name.hasSuffix(".service") ? name : name + ".service")
            i += 2
        case "-n", "--lines":
            guard i + 1 < args.count, let n = Int(args[i + 1]), n >= 0 else { fputs("journalctl: --lines requires a non-negative integer\n", stderr); exit(1) }
            o.lines = n
            i += 2
        case "-h", "--help": usage()
        case "--version": print("systemd-macos 0.1.0"); exit(0)
        default:
            if args[i].hasPrefix("-") { fputs("journalctl: unknown option \(args[i])\n", stderr); exit(1) }
            let name = args[i]
            o.units.append(name.hasSuffix(".service") ? name : name + ".service")
            i += 1
        }
    }
    return o
}

func urls(for unit: String) -> [URL] {
    [
        SystemdPaths.logDirectory.appendingPathComponent("\(unit).stdout.log"),
        SystemdPaths.logDirectory.appendingPathComponent("\(unit).stderr.log")
    ]
}

func tail(_ text: String, count: Int) -> String {
    guard count > 0 else { return "" }
    return Array(text.components(separatedBy: .newlines).suffix(count + 1))
        .joined(separator: "\n")
        .trimmingCharacters(in: .newlines)
}

func discoverUnits() -> [String] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: SystemdPaths.logDirectory.path) else { return [] }
    return Array(Set(names.compactMap { name in
        guard name.hasSuffix(".stdout.log") else { return nil }
        return String(name.dropLast(".stdout.log".count))
    })).sorted()
}

func printLogs(_ units: [String], lines: Int) {
    for unit in units {
        for url in urls(for: unit) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let output = tail(text, count: lines)
            if !output.isEmpty { print(output) }
        }
    }
    fflush(stdout)
}

func follow(_ units: [String]) -> Never {
    var offsets: [String: UInt64] = [:]
    for unit in units {
        for url in urls(for: unit) {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            offsets[url.path] = size
        }
    }

    while true {
        for unit in units {
            for url in urls(for: unit) {
                let oldOffset = offsets[url.path] ?? 0
                guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? handle.close() }
                do {
                    try handle.seek(toOffset: oldOffset)
                    let data = handle.readDataToEndOfFile()
                    if !data.isEmpty {
                        if let text = String(data: data, encoding: .utf8) {
                            print(text, terminator: "")
                            fflush(stdout)
                        }
                        offsets[url.path] = oldOffset + UInt64(data.count)
                    }
                } catch { }
            }
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
}

let options = parse(CommandLine.arguments)
let units = options.units.isEmpty ? discoverUnits() : options.units
if units.isEmpty {
    print("-- No systemd-macos logs found --")
    exit(0)
}
printLogs(units, lines: options.lines)
if options.follow { follow(units) }
