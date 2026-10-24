// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "IPhoneUseRunnerSupport",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "IPhoneUseRunnerSupport", type: .static, targets: ["IPhoneUseRunnerSupport"])],
    targets: [
        .target(name: "IPhoneUseRunnerSupport"),
        .testTarget(name: "IPhoneUseRunnerSupportTests", dependencies: ["IPhoneUseRunnerSupport"])
    ]
)
