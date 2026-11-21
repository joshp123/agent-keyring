// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentKeyringFeature",
    platforms: [.macOS(.v26), .iOS(.v26), .watchOS(.v26)],
    products: [
        .library(name: "AgentKeyringRelaySupport", targets: ["AgentKeyringRelaySupport"]),
        .library(name: "AgentKeyringPhoneApprover", targets: ["AgentKeyringPhoneApprover"]),
        .library(name: "AgentKeyringCredentialImport", targets: ["AgentKeyringCredentialImport"]),
        .library(name: "AgentKeyringProtocol", targets: ["AgentKeyringProtocol"]),
        .library(name: "AgentKeyringSealing", targets: ["AgentKeyringSealing"]),
        .library(name: "AgentKeyringWatchCore", targets: ["AgentKeyringWatchCore"]),
        .library(name: "AgentKeyringApprovalCore", targets: ["AgentKeyringApprovalCore"]),
        .library(name: "AgentKeyringApprovalUI", targets: ["AgentKeyringApprovalUI"]),
        .library(name: "AgentKeyringDesign", targets: ["AgentKeyringDesign"]),
        .library(name: "AgentKeyringScreenBackends", targets: ["AgentKeyringScreenBackends"]),
        .library(name: "AgentKeyringTestSupport", targets: ["AgentKeyringTestSupport"]),
        .library(name: "AgentKeyringFeature", targets: ["AgentKeyringFeature"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1")
    ],
    targets: [
        .executableTarget(name: "PanelRender", dependencies: ["AgentKeyringApprovalUI"], path: "Tools/PanelRender"),
        .target(name: "AgentKeyringRelaySupport", dependencies: ["AgentKeyringProtocol", "AgentKeyringCredentialImport", "AgentKeyringApprovalCore"]),
        .target(name: "AgentKeyringPhoneApprover", dependencies: ["AgentKeyringSealing", "AgentKeyringRelaySupport", "AgentKeyringApprovalUI"]),
        .target(name: "AgentKeyringCredentialImport", dependencies: ["AgentKeyringApprovalCore"]),
        .target(name: "AgentKeyringProtocol", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]),
        // Sealed logins and signed answers, shared by the Mac, iPhone and Watch apps.
        .target(name: "AgentKeyringSealing", dependencies: ["AgentKeyringProtocol"]),
        .target(name: "AgentKeyringWatchCore", dependencies: ["AgentKeyringSealing", "AgentKeyringProtocol"]),
        .target(name: "AgentKeyringApprovalCore"),
        .target(name: "AgentKeyringApprovalUI", dependencies: ["AgentKeyringApprovalCore", "AgentKeyringDesign"]),
        // The page parts every screen is built from, with the check that nothing on them is cut off.
        .target(name: "AgentKeyringDesign"),
        // Joins the lease store and access rules to the screens (RFC 0007, U2 and U3).
        .target(name: "AgentKeyringScreenBackends", dependencies: ["AgentKeyringApprovalUI", "AgentKeyringFeature", "AgentKeyringProtocol", "AgentKeyringSealing"]),
        .target(name: "AgentKeyringFeature", dependencies: ["AgentKeyringRelaySupport", "AgentKeyringProtocol", "AgentKeyringSealing", "AgentKeyringApprovalCore", "AgentKeyringCredentialImport"]),
        .target(name: "AgentKeyringTestSupport", dependencies: ["AgentKeyringFeature"], path: "TestSupport"),
        .testTarget(name: "AgentKeyringDesignTests", dependencies: ["AgentKeyringDesign"]),
        .testTarget(name: "AgentKeyringSealingTests", dependencies: ["AgentKeyringSealing", "AgentKeyringProtocol", "AgentKeyringWatchCore"]),
        .testTarget(name: "AgentKeyringFeatureTests", dependencies: ["AgentKeyringTestSupport", "AgentKeyringFeature", "AgentKeyringApprovalCore", "AgentKeyringApprovalUI", "AgentKeyringPhoneApprover"]),
    ]
)
