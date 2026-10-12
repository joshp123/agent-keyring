// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ax-readback",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "ax-readback")]
)
