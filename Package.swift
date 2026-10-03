// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "padmend",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "padmend", targets: ["padmend"]),
        .library(name: "PadmendCore", targets: ["PadmendCore"]),
    ],
    targets: [
        .target(name: "CMultitouch", linkerSettings: [
            .linkedFramework("CoreFoundation"),
        ]),
        .target(name: "PadmendCore"),
        .target(name: "PadmendKit", dependencies: ["CMultitouch", "PadmendCore"]),
        .executableTarget(name: "padmend", dependencies: ["PadmendKit", "PadmendCore"]),
        .executableTarget(name: "padmend-tests", dependencies: ["PadmendCore"]),
    ]
)
