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
        .library(name: "SystemdCore", targets: ["SystemdCore"])
    ],
    targets: [
        .target(name: "SystemdCore"),
        .executableTarget(name: "SystemdDaemon", dependencies: ["SystemdCore"]),
        .executableTarget(name: "Systemctl", dependencies: ["SystemdCore"]),
        .testTarget(name: "SystemdCoreTests", dependencies: ["SystemdCore"])
    ]
)
