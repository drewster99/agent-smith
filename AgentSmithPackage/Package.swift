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
        .package(url: "git@github.com:drewster99/swift-llm-kit.git", from: "0.0.6")
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
