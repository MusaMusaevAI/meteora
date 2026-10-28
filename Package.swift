// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Volant",
    defaultLocalization: "ru",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Volant", targets: ["Volant"]),
    ],
    targets: [
        // Pure logic + media pipeline. No UI, no networking.
        .target(
            name: "VolantCore",
            path: "Sources/VolantCore"
        ),
        .executableTarget(
            name: "Volant",
            dependencies: ["VolantCore"],
            path: "Sources/Volant"
        ),
        .testTarget(
            name: "VolantCoreTests",
            dependencies: ["VolantCore"],
            path: "Tests/VolantCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
