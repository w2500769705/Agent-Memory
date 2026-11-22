// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentMemory",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentMemory", targets: ["AgentMemoryApp"]),
        .executable(name: "agent-memory-mcp", targets: ["AgentMemoryMCP"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.8.0")
    ],
    targets: [
        .target(name: "AgentMemoryCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "AgentMemoryApp", dependencies: ["AgentMemoryCore"]),
        .executableTarget(name: "AgentMemoryMCP", dependencies: ["AgentMemoryCore"]),
        .executableTarget(name: "AgentMemorySmoke", dependencies: ["AgentMemoryCore"], path: "Tests/AgentMemorySmoke")
    ],
    swiftLanguageModes: [.v5]
)
