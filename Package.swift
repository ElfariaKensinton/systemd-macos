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
        .library(name: "SystemdCore", targets: ["SystemdCore"])
    ],
    targets: [
        .target(name: "SystemdCore"),
        .executableTarget(name: "SystemdDaemon", dependencies: ["SystemdCore"]),
        .executableTarget(name: "Systemctl", dependencies: ["SystemdCore"]),
        .executableTarget(name: "Journalctl", dependencies: ["SystemdCore"]),
        .testTarget(name: "SystemdCoreTests", dependencies: ["SystemdCore"])
    ]
)
