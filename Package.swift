// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Arca",
    platforms: [
        .macOS("26.0")  // macOS Sequoia
    ],
    dependencies: [
        .package(path: "containerization"),  // Use local containerization submodule
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.87.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.4"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.23.0"),
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.4"),
    ],
    targets: [
        // Main executable target
        .executableTarget(
            name: "Arca",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
                "ArcaDaemon",
            ]
        ),

        // Test helper executable (requires signing with entitlements)
        .executableTarget(
            name: "ArcaTestHelper",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                "ContainerBridge",
            ]
        ),

        // Daemon server (HTTP/Unix socket server)
        .target(
            name: "ArcaDaemon",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
                "DockerAPI",
                "ContainerBridge",
            ]
        ),

        // Docker API models and handlers
        .target(
            name: "DockerAPI",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                "ContainerBridge",
            ]
        ),

        // Apple Containerization API wrapper
        .target(
            name: "ContainerBridge",
            dependencies: [
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationEXT4", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SQLite", package: "SQLite.swift"),
            ]
        ),

        // Tests
        .testTarget(
            name: "ArcaTests",
            dependencies: [
                "Arca",
                "ArcaDaemon",
                "DockerAPI",
                "ContainerBridge",
            ]
        ),
    ]
)
