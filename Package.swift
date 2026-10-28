// swift-tools-version:5.10
import PackageDescription

// Static sherpa-onnx + ONNX Runtime libraries (universal2), fetched and
// hash-verified by scripts/fetch_vendor.sh into Vendor/sherpa-onnx/lib.
let sherpaLib = Context.packageDirectory + "/Vendor/sherpa-onnx/lib"
let sherpaLibs = [
    "sherpa-onnx-c-api", "sherpa-onnx-core", "kaldi-decoder-core", "sherpa-onnx-kaldifst-core",
    "sherpa-onnx-fstfar", "sherpa-onnx-fst", "kaldi-native-fbank-core", "kissfft-float",
    "onnxruntime", "ssentencepiece_core", "utf8proc",
]

let package = Package(
    name: "Meteora",
    defaultLocalization: "ru",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Meteora", targets: ["Meteora"]),
    ],
    targets: [
        // Pure logic + media pipeline. No UI, no networking.
        .target(
            name: "MeteoraCore",
            path: "Sources/MeteoraCore"
        ),
        // C API of sherpa-onnx (speech recognition runtime).
        .target(
            name: "CSherpaOnnx",
            path: "Sources/CSherpaOnnx",
            exclude: ["README.md"],
            linkerSettings: [.unsafeFlags(["-L", sherpaLib])]
                + sherpaLibs.map { .linkedLibrary($0) }
                + [.linkedLibrary("c++"), .linkedFramework("Foundation")]
        ),
        // On-device transcription with GigaAM-v3 + model download/verification.
        .target(
            name: "MeteoraASR",
            dependencies: ["MeteoraCore", "CSherpaOnnx"],
            path: "Sources/MeteoraASR"
        ),
        .executableTarget(
            name: "Meteora",
            dependencies: ["MeteoraCore", "MeteoraASR"],
            path: "Sources/Meteora"
        ),
        .testTarget(
            name: "MeteoraCoreTests",
            dependencies: ["MeteoraCore"],
            path: "Tests/MeteoraCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
