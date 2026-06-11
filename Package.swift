// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Peek",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "Peek",
            path: "Sources/Peek",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Security"),
            ]),
    ])
