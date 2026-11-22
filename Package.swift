// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SDCardChecker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SDCardChecker",
            path: "Sources/SDCardChecker",
            linkerSettings: [.linkedFramework("DiskArbitration")]
        )
    ]
)
