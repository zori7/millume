// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Millume",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Millume",
            path: "Sources/Millume",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
