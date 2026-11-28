// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AgentKeyringFeature",
    platforms: [.macOS(.v26), .iOS(.v26), .watchOS(.v26)],
    products: [
        .library(name: "AgentKeyringProtocol", targets: ["AgentKeyringProtocol"]),
        .library(name: "AgentKeyringApprovalCore", targets: ["AgentKeyringApprovalCore"]),
        .library(name: "AgentKeyringDesign", targets: ["AgentKeyringDesign"]),
        .library(name: "AgentKeyringSiteIcons", targets: ["AgentKeyringSiteIcons"]),
        .library(name: "AgentKeyringApprovalUI", targets: ["AgentKeyringApprovalUI"]),
        .library(name: "AgentKeyringWatchUI", targets: ["AgentKeyringWatchUI"]),
        .library(name: "AgentKeyringSealing", targets: ["AgentKeyringSealing"]),
        .library(name: "AgentKeyringEngine", targets: ["AgentKeyringEngine"]),
        .library(name: "AgentKeyringScreenBackends", targets: ["AgentKeyringScreenBackends"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1")
    ],
    targets: [
        .executableTarget(name: "PanelRender", dependencies: ["AgentKeyringApprovalUI", "AgentKeyringDesign", "AgentKeyringSealing"], path: "Tools/PanelRender"),
        .executableTarget(name: "TestPeer", dependencies: [
            "AgentKeyringApprovalCore", "AgentKeyringEngine", "AgentKeyringProtocol", "AgentKeyringSealing",
        ], path: "Tools/TestPeer"),
        .target(name: "AgentKeyringProtocol", dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")]),
        .target(name: "AgentKeyringApprovalCore"),
        // Sealed logins and signed answers, the relay and push clients, the iPhone's notice, Apple Watch's
        // state, and the "hunter2" sandbox keyring as protobuf. Everything the Watch app and the notification
        // extensions link: no CloudKit, no domain catalogue, no screens.
        .target(name: "AgentKeyringSealing", dependencies: ["AgentKeyringApprovalCore", "AgentKeyringProtocol"]),
        // The Mac's and iPhone's keyrings: the iCloud private database between them (Cloud), password import
        // and the offline domain catalogue (Import), and each device's engine (Mac, Phone). Mac/ is macOS only.
        .target(name: "AgentKeyringEngine", dependencies: ["AgentKeyringApprovalCore", "AgentKeyringProtocol", "AgentKeyringSealing"],
                resources: [.copy("Import/Resources/DomainCatalogue.tsv.zlib")]),
        // Apple Watch's pages, in a package target so the cut-off check can host them.
        .target(name: "AgentKeyringWatchUI", dependencies: ["AgentKeyringDesign", "AgentKeyringSealing"]),
        .target(name: "AgentKeyringSiteIcons", resources: [
            .copy("Resources/SiteIcons.bin"),
            .copy("Resources/psl.txt.zlib"),
        ]),
        .target(name: "AgentKeyringApprovalUI", dependencies: [
            "AgentKeyringApprovalCore",
            "AgentKeyringDesign",
            .target(name: "AgentKeyringSiteIcons", condition: .when(platforms: [.macOS])),
        ]),
        // The page parts every screen is built from, with the check that nothing on them is cut off.
        .target(name: "AgentKeyringDesign", resources: [
            .copy("Resources/AlloVariable.ttf"),
            .copy("Resources/OFL.txt"),
        ]),
        // Joins the lease store and access rules to the screens (RFC 0007, U2 and U3).
        .target(name: "AgentKeyringScreenBackends", dependencies: [
            "AgentKeyringApprovalCore", "AgentKeyringApprovalUI", "AgentKeyringDesign", "AgentKeyringEngine", "AgentKeyringProtocol",
            "AgentKeyringSealing",
        ]),
        .testTarget(name: "AgentKeyringDesignTests", dependencies: ["AgentKeyringDesign",
            .target(name: "AgentKeyringApprovalUI", condition: .when(platforms: [.macOS, .iOS])),
            .target(name: "AgentKeyringWatchUI", condition: .when(platforms: [.watchOS]))]),
        .testTarget(name: "AgentKeyringCopyTests"),
        .testTarget(name: "AgentKeyringSealingTests", dependencies: ["AgentKeyringProtocol", "AgentKeyringSealing"]),
        .testTarget(name: "AgentKeyringEngineTests", dependencies: [
            "AgentKeyringApprovalCore", "AgentKeyringApprovalUI", "AgentKeyringEngine", "AgentKeyringProtocol", "AgentKeyringScreenBackends",
            "AgentKeyringSealing", "AgentKeyringSiteIcons",
        ]),
    ]
)
