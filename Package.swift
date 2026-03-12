// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentSmith",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "AgentSmithKit", targets: ["AgentSmithKit"])
    ],
    targets: [
        .executableTarget(
            name: "AgentSmithApp",
            dependencies: ["AgentSmithKit"],
            path: "Sources/AgentSmithApp"
        ),
        .target(
            name: "AgentSmithKit",
            path: "Sources/AgentSmith"
        ),
        .testTarget(
            name: "AgentSmithTests",
            dependencies: ["AgentSmithKit"],
            path: "Tests/AgentSmithTests"
        )
    ]
)
