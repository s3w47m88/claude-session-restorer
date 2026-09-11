// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RestoreAIWindows",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "RestoreAIWindows",
            path: "Sources/RestoreAIWindows"
        )
    ]
)
