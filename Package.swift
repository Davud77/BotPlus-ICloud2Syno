// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SynologyPhotoSync",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "SynologyPhotoSync",
            targets: ["SynologyPhotoSync"]
        )
    ],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .executableTarget(
            name: "SynologyPhotoSync",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources"
        ),
        .testTarget(
            name: "SynologyPhotoSyncTests",
            dependencies: ["SynologyPhotoSync"],
            path: "Tests"
        )
    ]
)
