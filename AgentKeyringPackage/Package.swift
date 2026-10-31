// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentKeyringFeature",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "AgentKeyringRelaySupport", targets: ["AgentKeyringRelaySupport"]),
        .library(name: "AgentKeyringPhoneApprover", targets: ["AgentKeyringPhoneApprover"]),
        .library(name: "AgentKeyringPhoneVault", targets: ["AgentKeyringPhoneVault"]),
        .library(name: "AgentKeyringCredentialImport", targets: ["AgentKeyringCredentialImport"]),
        .library(name: "AgentKeyringProtocol", targets: ["AgentKeyringProtocol"]),
        .library(name: "AgentKeyringApprovalCore", targets: ["AgentKeyringApprovalCore"]),
        .library(name: "AgentKeyringFillerSupport", targets: ["AgentKeyringFillerSupport"]),
        .library(name: "AgentKeyringApprovalUI", targets: ["AgentKeyringApprovalUI"]),
        .library(name: "AgentKeyringScreenBackends", targets: ["AgentKeyringScreenBackends"]),
        .library(name: "AgentKeyringTestSupport", targets: ["AgentKeyringTestSupport"]),
        .library(name: "AgentKeyringFeature", targets: ["AgentKeyringFeature"]),
        .executable(name: "agent-keyring-authority-fixture", targets: ["AgentKeyringAuthorityFixture"]),
        .executable(name: "agent-keyring-relay-approver-fixture", targets: ["AgentKeyringRelayApproverFixture"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1")
    ],
    targets: [
        .target(name: "AgentKeyringRelaySupport", dependencies: ["AgentKeyringProtocol", "AgentKeyringCredentialImport"]),
        .target(name: "AgentKeyringPhoneApprover", dependencies: ["AgentKeyringRelaySupport", "AgentKeyringPhoneVault", "AgentKeyringApprovalUI"]),
        .target(name: "AgentKeyringPhoneVault", dependencies: ["AgentKeyringCredentialImport", "AgentKeyringProtocol"]),
        .target(name: "AgentKeyringCredentialImport"),
        .target(name: "AgentKeyringProtocol", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]),
        .target(name: "AgentKeyringApprovalCore"),
        .target(name: "AgentKeyringFillerSupport"),
        .target(name: "AgentKeyringApprovalUI"),
        // Joins the lease store and access rules to the screens (RFC 0007, U2 and U3).
        .target(name: "AgentKeyringScreenBackends", dependencies: ["AgentKeyringApprovalUI", "AgentKeyringFeature", "AgentKeyringProtocol"]),
        .executableTarget(name: "AgentKeyringDesignGallery", dependencies: ["AgentKeyringApprovalUI", "AgentKeyringScreenBackends", "AgentKeyringFeature", "AgentKeyringProtocol"], path: "Tools/AgentKeyringDesignGallery"),
        .target(name: "AgentKeyringFeature", dependencies: ["AgentKeyringProtocol", "AgentKeyringFillerSupport", "AgentKeyringApprovalCore", "AgentKeyringCredentialImport"]),
        .target(name: "AgentKeyringTestSupport", dependencies: ["AgentKeyringFeature"], path: "TestSupport"),
        .executableTarget(name: "AgentKeyringAuthorityFixture", dependencies: ["AgentKeyringFeature", "AgentKeyringTestSupport"], path: "Tools/AgentKeyringAuthorityFixture"),
        .executableTarget(name: "AgentKeyringRelayApproverFixture", dependencies: ["AgentKeyringFeature"], path: "Tools/AgentKeyringRelayApproverFixture"),
        .testTarget(name: "AgentKeyringApprovalCoreTests", dependencies: ["AgentKeyringApprovalCore"]),
        .testTarget(name: "AgentKeyringFeatureTests", dependencies: ["AgentKeyringTestSupport", "AgentKeyringFeature", "AgentKeyringApprovalCore"]),
    ]
)
