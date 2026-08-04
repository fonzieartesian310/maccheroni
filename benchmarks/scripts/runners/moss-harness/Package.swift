// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MaccheroniMossHarness",
    platforms: [.macOS("15.0")],
    dependencies: [
        .package(
            url: "https://github.com/soniqo/speech-swift.git",
            revision: "37c99dd856cfacfe952b2e48ecdb3c9dedc77625"
        ),
    ],
    targets: [
        .executableTarget(
            name: "MaccheroniMossHarness",
            dependencies: [
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "MossTranscribe", package: "speech-swift"),
            ]
        ),
    ]
)
