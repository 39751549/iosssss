// swift-tools-version:5.9
//
// 语音房 iOS 原生客户端
//
// 为什么用 SPM 而不是 CocoaPods：
//   SPM 是 Xcode 原生支持的依赖方式，云端打包（Codemagic / GitHub Actions）
//   不需要额外安装 pod，克隆下来直接用 xcodebuild 就能编译，最省事。
//
// 打开方式（在 Mac 上）：
//   Xcode → File → Open → 选择本文件所在的目录（ios-native/VoiceRoom）
//   Xcode 会自动解析 Package.swift 并拉取 WebRTC 依赖。
//
import PackageDescription

let package = Package(
    name: "VoiceRoom",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(name: "VoiceRoomKit", targets: ["VoiceRoom"])
    ],
    dependencies: [
        // Google 官方 WebRTC 预编译包（约 100MB，首次解析需要联网）
        //
        // 说明：这是目前 iOS 上最省事的 WebRTC 集成方式。
        // 该包由 LiveKit 团队维护的 WebRTC 二进制镜像，版本号对应 Google WebRTC 的 M 版本。
        .package(url: "https://github.com/stasel/WebRTC.git", from: "121.0.0")
    ],
    targets: [
        .target(
            name: "VoiceRoom",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC")
            ],
            path: "Sources"
        )
    ]
)
