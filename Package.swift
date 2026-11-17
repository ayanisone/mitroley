// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Foley",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "Foley", path: "Sources/Foley"),
        .executableTarget(name: "foley-mcp", path: "Sources/foley-mcp"),
    ]
)
