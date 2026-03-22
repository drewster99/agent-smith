// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftLLMKit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SwiftLLMKit", targets: ["SwiftLLMKit"])
    ],
    targets: [
        .target(
            name: "SwiftLLMKit",
            path: "Sources/SwiftLLMKit"
        ),
        .testTarget(
            name: "SwiftLLMKitTests",
            dependencies: ["SwiftLLMKit"],
            path: "Tests/SwiftLLMKitTests"
        )
    ]
)
