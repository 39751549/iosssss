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
        // Google 官方 WebRTC 预编译包
        //
        // ⚠️ 必须保持跟进新版本：M121 是 2024 年的二进制，早于 iOS 26 的新
        // CoreAudio/VoiceProcessingIO 行为，实测在 iOS 26 上「对运行中的音频单元
        // 启动录音」会被系统直接干掉（开麦闪退，且任何异常钩子都抓不到）。
        // M154（2026-09）已适配新系统。
        .package(url: "https://github.com/stasel/WebRTC.git", from: "154.0.0")
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
