// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OrbWatch",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "OrbWatch",
            path: "Sources/OrbWatch"
        )
    ]
)
