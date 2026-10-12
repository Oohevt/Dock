// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DockGroups",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DockGroups", targets: ["DockGroups"])
    ],
    targets: [
        .executableTarget(
            name: "DockGroups",
            path: "Sources",
            resources: [.process("Resources")]
        )
    ]
)
