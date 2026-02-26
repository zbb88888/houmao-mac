// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "houmao",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "houmao", targets: ["houmao"])
    ],
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI.git", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "houmao",
            dependencies: ["OpenAI"],
            path: "mac/houmao/houmao",
            exclude: ["Assets.xcassets"]
        ),
        .testTarget(
            name: "houmaoTests",
            dependencies: ["houmao"],
            path: "mac/houmao/houmaoTests"
        )
    ]
)
