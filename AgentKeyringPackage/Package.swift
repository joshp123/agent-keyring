// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AgentKeyringFeature",
    platforms: [.macOS(.v26), .iOS(.v17)],
    products: [
        .library(name: "AgentKeyringApprovalCore", targets: ["AgentKeyringApprovalCore"]),
        .library(name: "AgentKeyringFillerSupport", targets: ["AgentKeyringFillerSupport"]),
        .library(name: "AgentKeyringTestSupport", targets: ["AgentKeyringTestSupport"]),
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "AgentKeyringFeature",
            targets: ["AgentKeyringFeature"]
        ),
        .executable(
            name: "agent-keyring",
            targets: ["AgentKeyringCLI"]
        ),
        .executable(
            name: "agent-keyring-fixture",
            targets: ["AgentKeyringFixture"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.2")
    ],
    targets: [
        .target(name: "AgentKeyringApprovalCore"),
        .target(name: "AgentKeyringFillerSupport"),
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "AgentKeyringFeature",
            dependencies: ["AgentKeyringFillerSupport", "AgentKeyringApprovalCore"]
        ),
        .target(name: "AgentKeyringTestSupport", dependencies: ["AgentKeyringFeature"], path: "TestSupport"),
        .executableTarget(
            name: "AgentKeyringCLI",
            dependencies: [
                "AgentKeyringFeature",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "AgentKeyringFixture",
            dependencies: ["AgentKeyringFeature", "AgentKeyringTestSupport"],
            path: "Tools/AgentKeyringFixture"
        ),
        .testTarget(name: "AgentKeyringApprovalCoreTests", dependencies: ["AgentKeyringApprovalCore"]),
        .testTarget(
            name: "AgentKeyringFeatureTests",
            dependencies: [
                "AgentKeyringTestSupport",
                "AgentKeyringFeature",
                "AgentKeyringApprovalCore"
            ]
        ),
        .testTarget(
            name: "AgentKeyringCLITests",
            dependencies: [
                "AgentKeyringTestSupport",
                "AgentKeyringCLI",
                "AgentKeyringFeature",
            ]
        ),
    ]
)
