// swift-tools-version:5.9
import PackageDescription

/// App Intents (Shortcuts actions, widget buttons) need the compiler's constant values to build their metadata;
/// release builds write them next to the products, and build-app.sh turns them into Metadata.appintents.
func constValues(_ module: String) -> [SwiftSetting] {
    [.unsafeFlags(["-emit-const-values-path", Context.packageDirectory + "/.build/\(module).swiftconstvalues",
                   "-Xfrontend", "-const-gather-protocols-file", "-Xfrontend", Context.packageDirectory + "/Scripts/appintents-protocols.json"],
                  .when(configuration: .release))]
}

let package = Package(
    name: "MusicAmp",
    // macOS 26 on Apple Silicon: on-device AI (Foundation Models, SpeechAnalyzer) is part of the app.
    platforms: [.macOS("26.0")],
    dependencies: [
        // Live Video's local story model (Qwen, sideloaded): Apple's MLX. mlx-swift is pinned to the version whose
        // precompiled shaders (mlx.metallib, MLX 0.32.2) the app downloads next to the model; see
        // Scripts/mlx-precompiled-shaders.sh.
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "7eb77efa4e8fb56183b905904d122e66ebdb422e"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.5"),
    ],
    targets: [
        .target(name: "MusicAmpShared", path: "Sources/MusicAmpShared"),
        // Apple's Core ML Stable Diffusion pipeline (MIT), vendored: Live Video's images, on the Neural Engine.
        .target(name: "StableDiffusion", path: "Sources/StableDiffusion", exclude: ["LICENSE.md", "README.md"]),
        .executableTarget(name: "MusicAmp", dependencies: [
            "MusicAmpShared", "StableDiffusion",
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ], path: "Sources/MusicAmp",
                          swiftSettings: constValues("MusicAmp")),
        // WidgetKit extension, packaged by build-app.sh as Contents/PlugIns/MusicAmpWidget.appex.
        .executableTarget(name: "MusicAmpWidget", dependencies: ["MusicAmpShared"], path: "Sources/MusicAmpWidget",
                          swiftSettings: constValues("MusicAmpWidget") + [.unsafeFlags(["-application-extension"])],
                          // App extensions start in Foundation's NSExtensionMain (as Xcode links them): it registers the
                          // extension with ExtensionFoundation, then runs the @main WidgetBundle. Without it the widget
                          // traps at launch ("Failed to create running extension").
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension", "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]),
    ]
)
