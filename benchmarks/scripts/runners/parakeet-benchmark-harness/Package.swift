// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MaccheroniParakeetBenchmarkHarness",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "5390df9752c8fc583596018360c5fd70d6fa6c75"
        ),
    ],
    targets: [
        .executableTarget(
            name: "MaccheroniParakeetBenchmarkHarness",
            dependencies: [
                .product(name: "FluidAudio", package: "fluidaudio"),
            ]
        ),
    ]
)
