// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Veil",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Veil", targets: ["Veil"]),
        .executable(name: "veil-mcp", targets: ["veil-mcp"]),
    ],
    dependencies: [
        // Auto-updates for the downloadable app (signed appcast, EdDSA-verified updates).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        // Everything that touches data or enforces policy. No UI.
        .target(name: "VeilCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // The menu bar app. Hosts the gate and the MCP server.
        .executableTarget(name: "Veil", dependencies: ["VeilCore", .product(name: "Sparkle", package: "Sparkle")]),
        // Tiny stdio <-> socket relay for MCP clients. Has no access to any data.
        .executableTarget(name: "veil-mcp"),
        .testTarget(name: "VeilCoreTests", dependencies: ["VeilCore"]),
    ],
    swiftLanguageModes: [.v5]
)
