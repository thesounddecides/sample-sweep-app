// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "sample-sweep",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(name: "SweepCore", dependencies: ["CZlib"]),
        .executableTarget(name: "sweepcheck", dependencies: ["SweepCore"]),
        .executableTarget(name: "sweeptool", dependencies: ["SweepCore"]),
        .executableTarget(name: "SampleSweepApp", dependencies: ["SweepCore"],
                          path: "Sources/SampleSweep"),
    ]
)
