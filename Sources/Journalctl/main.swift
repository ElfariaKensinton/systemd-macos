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
    print("  -x, --catalog      Show explanatory messages (accepted)")
    print("  -e, --pager-end    Jump to end of journal (accepted)")
    print("      --no-pager     Disable the pager")
    print("  -h, --help         Show this help")
    exit(0)
}

func parse(_ args: [String]) -> Options {
    var o = Options()
    var i = 1
    while i < args.count {
        let arg = args[i]
        if arg == "--" {
            i += 1
            while i < args.count {
                let name = args[i]
                o.units.append(name.hasSuffix(".service") ? name : name + ".service")
                i += 1
            }
            continue
        }

        if arg == "-f" || arg == "--follow" {
            o.follow = true
            i += 1
            continue
        }
        if arg == "--no-pager" {
            i += 1
            continue
        }
        if arg == "-h" || arg == "--help" {
            usage()
        }
        if arg == "--version" {
            print("systemd-macos 0.1.0")
            exit(0)
        }
        if arg == "--catalog" || arg == "--pager-end" {
            i += 1
            continue
        }
        if arg == "--unit" || arg == "-u" {
            guard i + 1 < args.count else { fputs("journalctl: --unit requires a unit name\n", stderr); exit(1) }
            let name = args[i + 1]
            o.units.append(name.hasSuffix(".service") ? name : name + ".service")
            i += 2
            continue
        }
        if arg == "--lines" || arg == "-n" {
            guard i + 1 < args.count, let n = Int(args[i + 1]), n >= 0 else { fputs("journalctl: --lines requires a non-negative integer\n", stderr); exit(1) }
            o.lines = n
            i += 2
            continue
        }

        if arg.hasPrefix("-") && !arg.hasPrefix("--") {
            let flags = Array(arg.dropFirst())
            var consumedUnit = false
            var consumedLines = false
            for flag in flags {
                switch flag {
                case "x", "e":
                    break
                case "f":
                    o.follow = true
                case "u":
                    guard i + 1 < args.count else { fputs("journalctl: -u requires a unit name\n", stderr); exit(1) }
                    let name = args[i + 1]
                    o.units.append(name.hasSuffix(".service") ? name : name + ".service")
                    consumedUnit = true
                case "n":
                    guard i + 1 < args.count, let n = Int(args[i + 1]), n >= 0 else { fputs("journalctl: -n requires a non-negative integer\n", stderr); exit(1) }
                    o.lines = n
                    consumedLines = true
                default:
                    fputs("journalctl: unknown option -\(flag)\n", stderr)
                    exit(1)
                }
            }
            if consumedUnit || consumedLines { i += 2 } else { i += 1 }
            continue
        }

        let name = arg
        o.units.append(name.hasSuffix(".service") ? name : name + ".service")
        i += 1
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