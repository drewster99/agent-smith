// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentSmithPackage",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "AgentSmithKit", targets: ["AgentSmithKit"])
    ],
    dependencies: [
        // Local path dependency during development of the built-in providers / agent-centric
        // settings work. Revert to a versioned git dependency before release.
        .package(path: "../../swift-llm-kit")
    ],
    targets: [
        .target(
            name: "AgentSmithKit",
            dependencies: [.product(name: "SwiftLLMKit", package: "swift-llm-kit")],
            path: "Sources/AgentSmithKit"
        ),
        .testTarget(
            name: "AgentSmithTests",
            dependencies: ["AgentSmithKit"],
            path: "Tests/AgentSmithTests"
        )
    ]
)
