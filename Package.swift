// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeHUD",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeHUD",
            path: "Sources/ClaudeHUD"
        )
    ]
)
