// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "systemd-macos",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "systemd", targets: ["SystemdDaemon"]),
        .executable(name: "systemctl", targets: ["Systemctl"]),
        .executable(name: "journalctl", targets: ["Journalctl"]),
        .executable(name: "systemd-exec-helper", targets: ["SystemdExecHelper"]),
        .library(name: "SystemdCore", targets: ["SystemdCore"])
    ],
    targets: [
        .target(name: "SystemdCore"),
        .executableTarget(name: "SystemdDaemon", dependencies: ["SystemdCore"]),
        .executableTarget(name: "Systemctl", dependencies: ["SystemdCore"]),
        .executableTarget(name: "Journalctl", dependencies: ["SystemdCore"]),
        .executableTarget(name: "SystemdExecHelper"),
        .testTarget(name: "SystemdCoreTests", dependencies: ["SystemdCore"])
    ]
)
