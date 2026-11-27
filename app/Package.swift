// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Tach",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TachCore", path: "Sources/TachCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "Tach", dependencies: ["TachCore"], path: "Sources/Tach"),
        .testTarget(name: "TachCoreTests", dependencies: ["TachCore"], path: "Tests/TachCoreTests"),
    ]
)
