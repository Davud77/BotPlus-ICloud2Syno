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
    dependencies: [],
    targets: [
        .executableTarget(
            name: "SynologyPhotoSync",
            dependencies: [],
            path: "Sources"
        ),
        .testTarget(
            name: "SynologyPhotoSyncTests",
            dependencies: ["SynologyPhotoSync"],
            path: "Tests"
        )
    ]
)
