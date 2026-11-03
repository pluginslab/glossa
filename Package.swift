// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Glossa",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Glossa",
            path: "Sources/Glossa",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
