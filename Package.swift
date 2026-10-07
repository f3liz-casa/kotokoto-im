// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "kotokoto-im",
    platforms: [.macOS(.v12)],
    targets: [
        // OS 非依存のロジック (単独キータップ判定)。Linux でもテスト可能。
        .target(name: "KotokotoCore"),
        .executableTarget(name: "kotokoto-im", dependencies: ["KotokotoCore"]),
        .testTarget(name: "KotokotoCoreTests", dependencies: ["KotokotoCore"]),
    ]
)
