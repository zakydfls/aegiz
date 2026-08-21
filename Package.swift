// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Aegiz",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Aegiz", targets: ["Aegiz"])
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "apps/macos/Frameworks/GhosttyKit.xcframework"
        ),
        .target(
            name: "AegizRPC",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ],
            path: "proto",
            plugins: [
                .plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf")
            ]
        ),
        .executableTarget(
            name: "Aegiz",
            dependencies: [
                "AegizRPC",
                "GhosttyKit",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
            ],
            path: "apps/macos/Sources/Aegiz",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("Foundation"),
                .linkedFramework("IOSurface"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .testTarget(
            name: "AegizTests",
            dependencies: ["Aegiz"],
            path: "apps/macos/Tests/AegizTests"
        ),
    ]
)
