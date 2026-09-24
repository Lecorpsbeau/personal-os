// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PersonalOSDashboard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "PersonalOSDashboard",
            targets: ["PersonalOSDashboard"]
        )
    ],
    targets: [
        .target(
            name: "DashboardCore",
            path: "Sources/DashboardCore"
        ),
        .executableTarget(
            name: "PersonalOSDashboard",
            dependencies: ["DashboardCore"],
            path: "Sources/PersonalOSDashboard"
        ),
        .testTarget(
            name: "DashboardCoreTests",
            dependencies: ["DashboardCore"],
            path: "Tests/DashboardCoreTests"
        )
    ]
)
