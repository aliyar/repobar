// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "RepoBarKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GitEngine", targets: ["GitEngine"]),
    ],
    targets: [
        .target(
            name: "GitEngine",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .testTarget(
            name: "GitEngineTests",
            dependencies: ["GitEngine"],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
