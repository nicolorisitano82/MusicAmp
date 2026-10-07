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
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MusicAmpShared", path: "Sources/MusicAmpShared"),
        .executableTarget(name: "MusicAmp", dependencies: ["MusicAmpShared"], path: "Sources/MusicAmp",
                          swiftSettings: constValues("MusicAmp")),
        // WidgetKit extension, packaged by build-app.sh as Contents/PlugIns/MusicAmpWidget.appex.
        .executableTarget(name: "MusicAmpWidget", dependencies: ["MusicAmpShared"], path: "Sources/MusicAmpWidget",
                          swiftSettings: constValues("MusicAmpWidget") + [.unsafeFlags(["-application-extension"])],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-application_extension"])]),
    ]
)
