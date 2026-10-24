// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iphone-use",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "iphone-use", targets: ["IPhoneUse"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.8.2"),
        .package(path: "packages/runner-support")
    ],
    targets: [
        .target(name: "AppleNativeBridge", cSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("Foundation")]),
        .target(name: "IPhoneUseCore", dependencies: [
            "AppleNativeBridge", .product(name: "IPhoneUseRunnerSupport", package: "runner-support")
        ]),
        .executableTarget(name: "IPhoneUse", dependencies: [
            "IPhoneUseCore", .product(name: "ArgumentParser", package: "swift-argument-parser")
        ]),
        .testTarget(name: "IPhoneUseCoreTests", dependencies: [
            "IPhoneUseCore", .product(name: "IPhoneUseRunnerSupport", package: "runner-support")
        ], exclude: ["Fixtures/README.md", "Fixtures/NativeText/README.md"], resources: [
            // Copy only regression inputs, preserving PNG bytes without bundling local files or documentation.
            .copy("Fixtures/Observations/app.json"),
            .copy("Fixtures/Observations/system-alert.json"),
            .copy("Fixtures/NativeText/encoded-source.png"),
            .copy("Fixtures/NativeText/encoded-0.png"),
            .copy("Fixtures/NativeText/encoded-1.png"),
            .copy("Fixtures/NativeText/encoded-2.png"),
            .copy("Fixtures/NativeText/encoded-3.png"),
            .copy("Fixtures/NativeText/encoded-4.png"),
            .copy("Fixtures/NativeText/encoded-5.png"),
            .copy("Fixtures/NativeText/caret-source.png"),
            .copy("Fixtures/NativeText/caret-1.png"),
            .copy("Fixtures/NativeText/caret-2.png"),
            .copy("Fixtures/NativeText/caret-3.png"),
            .copy("Fixtures/NativeText/caret-4.png"),
            .copy("Fixtures/NativeText/caret-5.png"),
            .copy("Fixtures/NativeText/caret-6.png")
        ])
    ]
)
