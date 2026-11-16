// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sotto",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sotto", targets: ["Sotto"]),
        .executable(name: "sotto-mac", targets: ["SottoCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.41.0")
    ],
    targets: [
        .target(
            name: "SottoCore",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            path: "Sources/SottoCore"
        ),
        .executableTarget(name: "Sotto", dependencies: ["SottoCore"], path: "Sources/Sotto"),
        .executableTarget(name: "SottoCLI", dependencies: ["SottoCore"], path: "Sources/SottoCLI"),
        .testTarget(
            name: "SottoCoreTests",
            dependencies: ["SottoCore"],
            path: "Tests/SottoCoreTests"
        ),
    ]
)
