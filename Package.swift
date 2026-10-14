// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Cove",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(name: "Sparkle", url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip", checksum: "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"),
        .executableTarget(
            name: "Cove",
            dependencies: ["Sparkle"],
            path: "Sources/Cove",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
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
