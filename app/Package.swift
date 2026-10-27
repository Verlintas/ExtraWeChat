// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ExtraWeChat",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ExtraWeChat", targets: ["ExtraWeChat"])
    ],
    targets: [
        .executableTarget(
            name: "ExtraWeChat",
            path: "Sources/ExtraWeChat",
            resources: [.process("Resources")]
        )
    ]
)
