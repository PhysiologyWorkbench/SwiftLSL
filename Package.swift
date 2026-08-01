// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftLSL",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "LSLCore", targets: ["LSLCore"]),
        .library(name: "LSL", targets: ["LSL"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "LSLCore"),
        .target(name: "LSL", dependencies: ["LSLCore"]),
        .executableTarget(
            name: "lsltool",
            dependencies: [
                "LSL",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "LSLCoreTests", dependencies: ["LSLCore"]),
        .testTarget(name: "LSLTests", dependencies: ["LSL"]),
    ]
)
