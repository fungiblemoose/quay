// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Quay",
    // Platform floor is macOS 14 so the package builds in tooling/CI, but Quay
    // only *works* at runtime on macOS 26+ where Apple's `container` CLI lives.
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "QuayCore", targets: ["QuayCore"]),
        .executable(name: "quayd", targets: ["quayd"]),
        .executable(name: "QuayBar", targets: ["QuayBar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "QuayCore",
            dependencies: ["Yams"]
        ),
        .executableTarget(
            name: "quayd",
            dependencies: ["QuayCore"]
        ),
        .executableTarget(
            name: "QuayBar",
            dependencies: ["QuayCore"]
        ),
        .testTarget(
            name: "QuayCoreTests",
            dependencies: ["QuayCore"]
        ),
    ]
)
