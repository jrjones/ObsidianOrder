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
            ],
            path: "obs/obs"
        ),
        // Tests for ObsidianModel
        .testTarget(
            name: "ObsidianModelTests",
            dependencies: ["ObsidianModel"],
            path: "Tests/ObsidianModelTests"
        ),
    ]
)