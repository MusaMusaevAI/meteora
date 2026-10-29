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
// Static llama.cpp (universal: arm64 with Metal, x86_64 CPU), built from
// pinned, verified source by scripts/build_llama.sh into Vendor/llama/lib.
// Static on purpose: an ad-hoc signed app with library validation can't load
// a third-party dynamic framework.
let llamaLib = Context.packageDirectory + "/Vendor/llama/lib"

let package = Package(
    name: "Meteora",
    defaultLocalization: "ru",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Meteora", targets: ["Meteora"]),
        // Isolated converter for rare formats, bundled as
        // Meteora.app/Contents/XPCServices/com.musamusaev.meteora.converter.xpc
        .executable(name: "MeteoraConverter", targets: ["MeteoraConverter"]),
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
        // C API of llama.cpp (on-device language model for meeting summaries).
        .target(
            name: "CLlama",
            path: "Sources/CLlama",
            exclude: ["README.md"],
            linkerSettings: [.unsafeFlags(["-L", llamaLib]), .linkedLibrary("meteora-llama"),
                             .linkedLibrary("c++"), .linkedFramework("Accelerate"),
                             .linkedFramework("Metal"), .linkedFramework("MetalKit"),
                             .linkedFramework("Foundation")]
        ),
        // On-device meeting summaries: llama.cpp wrapper, model download and
        // verification, map-reduce summarizer. No UI.
        .target(
            name: "MeteoraLLM",
            dependencies: ["MeteoraCore", "MeteoraASR", "CLlama"],
            path: "Sources/MeteoraLLM"
        ),
        // NSXPC protocol shared by the app and the converter service.
        .target(
            name: "MeteoraConverterProtocol",
            path: "Sources/MeteoraConverterProtocol"
        ),
        // XPC service: runs the bundled ffmpeg (sandbox-inherited) on file
        // descriptors passed by the app. No network, no file access.
        .executableTarget(
            name: "MeteoraConverter",
            dependencies: ["MeteoraConverterProtocol"],
            path: "Sources/MeteoraConverter"
        ),
        .executableTarget(
            name: "Meteora",
            dependencies: ["MeteoraCore", "MeteoraASR", "MeteoraLLM", "MeteoraConverterProtocol"],
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
