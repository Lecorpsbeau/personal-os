 // swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mac-detective",
    targets: [
        .target(
            name: "CProcessRusage",
            path: "Sources/CProcessRusage"
        ),
        .executableTarget(
            name: "mac-detective",
            dependencies: ["CProcessRusage"]
        ),
        .testTarget(
            name: "mac-detectiveTests",
            dependencies: ["mac-detective"]
        ),
    ]
)
