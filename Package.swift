// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DoulD",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DolbyCore", targets: ["DolbyCore"]),
        .library(name: "DolbyMetal", targets: ["DolbyMetal"]),
        .library(name: "DolbyDisplay", targets: ["DolbyDisplay"]),
        .executable(name: "DoulD", targets: ["DoulDApp"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "DolbyCore",
            dependencies: [],
            path: "Sources/DolbyCore"
        ),
        .target(
            name: "DolbyMetal",
            dependencies: ["DolbyCore"],
            path: "Sources/DolbyMetal",
            resources: [
                .process("Shaders")
            ]
        ),
        .target(
            name: "DolbyDisplay",
            dependencies: [],
            path: "Sources/DolbyDisplay"
        ),
        .executableTarget(
            name: "DoulDApp",
            dependencies: ["DolbyCore", "DolbyMetal", "DolbyDisplay"],
            path: "Sources/DoulDApp"
        ),
        .testTarget(
            name: "DoulDTests",
            dependencies: ["DolbyCore", "DolbyMetal", "DolbyDisplay"],
            path: "Tests/DoulDTests"
        )
    ]
)
