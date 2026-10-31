// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentKeyringFeature",
    platforms: [.macOS(.v26), .iOS(.v17)],
    products: [
        .library(name: "AgentKeyringProtocol", targets: ["AgentKeyringProtocol"]),
        .library(name: "AgentKeyringApprovalCore", targets: ["AgentKeyringApprovalCore"]),
        .library(name: "AgentKeyringFillerSupport", targets: ["AgentKeyringFillerSupport"]),
        .library(name: "AgentKeyringTestSupport", targets: ["AgentKeyringTestSupport"]),
        .library(name: "AgentKeyringFeature", targets: ["AgentKeyringFeature"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1")
    ],
    targets: [
        .target(name: "AgentKeyringProtocol", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]),
        .target(name: "AgentKeyringApprovalCore"),
        .target(name: "AgentKeyringFillerSupport"),
        .target(name: "AgentKeyringFeature", dependencies: ["AgentKeyringProtocol", "AgentKeyringFillerSupport", "AgentKeyringApprovalCore"]),
        .target(name: "AgentKeyringTestSupport", dependencies: ["AgentKeyringFeature"], path: "TestSupport"),
        .testTarget(name: "AgentKeyringApprovalCoreTests", dependencies: ["AgentKeyringApprovalCore"]),
        .testTarget(name: "AgentKeyringFeatureTests", dependencies: ["AgentKeyringTestSupport", "AgentKeyringFeature", "AgentKeyringApprovalCore"]),
    ]
)
