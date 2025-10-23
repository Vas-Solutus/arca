// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "arca-tap-forwarder",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "arca-tap-forwarder",
            targets: ["arca-tap-forwarder"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.2"),
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.27.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.87.0"),
    ],
    targets: [
        .executableTarget(
            name: "arca-tap-forwarder",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        )
    ]
)
