// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AzurePimCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AzurePimCore", targets: ["AzurePimCore"])
    ],
    targets: [
        .target(name: "AzurePimCore"),
        .testTarget(name: "AzurePimCoreTests", dependencies: ["AzurePimCore"])
    ]
)
