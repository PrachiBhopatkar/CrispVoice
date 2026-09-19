// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BedrockSDKBridge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BedrockSDKBridge", type: .static, targets: ["BedrockSDKBridge"])
    ],
    dependencies: [
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", exact: "1.7.47")
    ],
    targets: [
        .target(
            name: "BedrockSDKBridge",
            dependencies: [
                .product(name: "AWSBedrockRuntime", package: "aws-sdk-swift"),
                .product(name: "AWSSDKIdentity", package: "aws-sdk-swift")
            ]
        ),
        .testTarget(
            name: "BedrockSDKBridgeTests",
            dependencies: ["BedrockSDKBridge"]
        )
    ]
)
