// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "obsidian-order",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "obs",
            targets: ["obs"]
        ),
    ],
    dependencies: [
        // Swift Argument Parser for CLI
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.0.0"),
        // YAML parsing for front-matter
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        // Markdown parsing for content
        // Using main branch until a stable release is tagged
        .package(url: "https://github.com/apple/swift-markdown.git", branch: "main"),
        // SQLite support for VaultIndex
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.13.3"),
    ],
    targets: [
        // Core parsing model: front-matter, links, tasks
        .target(
            name: "ObsidianModel",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/ObsidianModel"
        ),
        .executableTarget(
            name: "obs",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                // Core parsing model
                "ObsidianModel",
                // Vault indexing
                "VaultIndex",
                // Calendar integration
                "GraphClient",
                // SQLite for querying index
                .product(name: "SQLite", package: "SQLite.swift"),
                // YAML parsing for CLI config (Shell)
                .product(name: "Yams", package: "Yams"),
                // YAML config parsing (already included above)
            ],
            path: "obs/obs"
        ),
        // Tests for ObsidianModel
        .testTarget(
            name: "ObsidianModelTests",
            dependencies: ["ObsidianModel"],
            path: "Tests/ObsidianModelTests"
        ),
        // Vault indexer: scans vault and populates SQLite schema
        .target(
            name: "VaultIndex",
            dependencies: [
                "ObsidianModel",
                .product(name: "SQLite", package: "SQLite.swift"),
            ],
            path: "Sources/VaultIndex"
        ),
        // Calendar integration client (stub)
        .target(
            name: "GraphClient",
            dependencies: [],
            path: "Sources/GraphClient"
        ),
        // Tests for VaultIndex scanning
        .testTarget(
            name: "VaultIndexTests",
            dependencies: ["VaultIndex"],
            path: "Tests/VaultIndexTests"
        ),
        .testTarget(
            name: "ObsTests",
            dependencies: [
                "obs",
                "ObsidianModel",
                "GraphClient",
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Tests/ObsTests"
        ),
    ]
)