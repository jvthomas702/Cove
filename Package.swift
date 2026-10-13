// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Cove",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Cove",
            path: "Sources/Cove",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .testTarget(
            name: "CoveTests",
            dependencies: ["Cove"],
            path: "Tests/CoveTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
