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
        // ⚠️ 版本适配是双刃剑，实测结论（2026-10）：
        // - M121：在 iOS 13~17 上久经考验；唯一问题是「中途补音轨+重协商」会崩 ——
        //   该路径已通过「预建禁用音轨、开麦只翻 isEnabled」从代码中根除。
        // - M154：为 iOS 26 而生，但其新音频设备模块（ADM）在 **iOS 15.1.1** 上
        //   连建立 P2P 连接（pc 创建 / addTransceiver / addTrack）都会被当场杀死
        //   （面包屑实测，无任何异常/信号）。用户设备就是 iOS 15.1.1。
        // 结论：钉在 121，配合零重协商架构，两头都绕开。
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
