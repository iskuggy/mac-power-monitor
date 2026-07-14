// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacPowerMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacPowerMonitor"
        ),
        .testTarget(
            name: "MacPowerMonitorTests",
            dependencies: ["MacPowerMonitor"]
        ),
    ]
)
