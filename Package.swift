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
    targets: [
        .target(name: "MusicAmpShared", path: "Sources/MusicAmpShared"),
        // Apple's Core ML Stable Diffusion pipeline (MIT), vendored: Live Video's images, on the Neural Engine.
        .target(name: "StableDiffusion", path: "Sources/StableDiffusion", exclude: ["LICENSE.md", "README.md"]),
        .executableTarget(name: "MusicAmp", dependencies: ["MusicAmpShared", "StableDiffusion"], path: "Sources/MusicAmp",
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
