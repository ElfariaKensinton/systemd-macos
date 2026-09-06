import Foundation
import SystemdCore

#if canImport(Darwin)
import Darwin
#endif

func colorizedStatusOutput(_ output: String, statuses: [UnitStatus], plain: Bool) -> String {
    guard !plain, isatty(STDOUT_FILENO) == 1 else { return output }

    let reset = "\u{001B}[0m"
    let green = "\u{001B}[38;2;141;247;122m"
    let red = "\u{001B}[31m"
    let yellow = "\u{001B}[33m"
    let dim = "\u{001B}[2m"
    let dashedUnderline = "\u{001B}[4:5m"
    let bold = "\u{001B}[1m"

    let blocks = output.components(separatedBy: "\n\n")
    var rendered: [String] = []

    for (index, block) in blocks.enumerated() {
        guard !block.isEmpty else { continue }
        let status = index < statuses.count ? statuses[index] : nil

        let stateColor: String
        if status?.result != "success" {
            stateColor = red
        } else {
            switch status?.subState {
            case "active": stateColor = green
            case "activating", "exited": stateColor = yellow
            default: stateColor = dim
            }
        }

        var lines = block.components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("●") || first.hasPrefix("○") {
            let bullet = String(first.prefix(1))
            lines[0] = stateColor + bullet + reset + String(first.dropFirst())
        }

        for i in lines.indices {
            var line = lines[i]
            if line.hasPrefix("     Loaded: loaded (") {
                let prefix = "     Loaded: loaded ("
                if let semicolon = line.firstIndex(of: ";") {
                    let pathStart = line.index(line.startIndex, offsetBy: prefix.count)
                    let path = String(line[pathStart..<semicolon])
                    let before = String(line[..<pathStart])
                    let after = String(line[semicolon...])
                    line = before + dashedUnderline + path + reset + after
                }
                line = line.replacingOccurrences(of: "; enabled", with: "; \(bold)\(green)enabled\(reset)")
                line = line.replacingOccurrences(of: "; disabled", with: "; \(bold)\(red)disabled\(reset)")
            } else if line.hasPrefix("     Active:") {
                if line.contains("active (running)") {
                    line = line.replacingOccurrences(of: "active (running)", with: "\(bold)\(green)active (running)\(reset)")
                } else if line.contains("activating (start)") {
                    line = line.replacingOccurrences(of: "activating (start)", with: "\(bold)\(yellow)activating (start)\(reset)")
                } else if line.contains("inactive (exited)") {
                    line = line.replacingOccurrences(of: "inactive (exited)", with: "\(bold)\(yellow)inactive (exited)\(reset)")
                } else if line.contains("inactive (dead)") {
                    line = line.replacingOccurrences(of: "inactive (dead)", with: "\(bold)\(dim)inactive (dead)\(reset)")
                }
            } else if line.hasPrefix("TriggeredBy:") {
                line = line.replacingOccurrences(of: "●", with: "\(green)●\(reset)")
            } else if line.hasPrefix("     Docs: ") {
                let prefix = "     Docs: "
                line = prefix + String(line.dropFirst(prefix.count))
            } else if line.hasPrefix("   Main PID:") {
                line = bold + line + reset
            }
            lines[i] = line
        }

        rendered.append(lines.joined(separator: "\n"))
    }

    return rendered.joined(separator: "\n\n")
}
