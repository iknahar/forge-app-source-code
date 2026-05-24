// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Forge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Forge", targets: ["Forge"])
    ],
    dependencies: [
        // HotKey for global keyboard shortcuts
        // .package(url: "https://github.com/soffes/HotKey.git", from: "0.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "Forge",
            dependencies: [],
            path: "Forge/Sources",
            resources: [
                .process("../Resources")
            ]
        ),
        .testTarget(
            name: "ForgeTests",
            dependencies: ["Forge"],
            path: "ForgeTests"
        )
    ]
)
