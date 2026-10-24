// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iphone-use",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "iphone-use", targets: ["IPhoneUse"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.5.0"),
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
        ], resources: [.copy("Fixtures")])
    ]
)
