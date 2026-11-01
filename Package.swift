// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuickShare-Mac",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.26.0"),
    ],
    targets: [
        .executableTarget(
            name: "QuickShare-Mac",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources"
        ),
    ]
)
