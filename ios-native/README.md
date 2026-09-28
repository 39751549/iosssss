# 语音房 iOS 原生客户端

真·原生 SwiftUI 应用（不是套壳）。语音走 WebRTC 点对点，音乐、礼物、公屏、VIP 全部原生实现。

---

## 一、这个 App 有什么

| 功能 | 说明 |
|---|---|
| 🎙 实时语音 | WebRTC P2P mesh，3 人小房间两两互联，不经过媒体服务器 |
| 🚪 房间 | 创建房间、6 位房间号进房、改名、6 套背景主题 |
| 👤 名片 | 昵称 / 头像（相册选图自动压缩）/ 性别 / 个性签名 |
| 🔊 麦克风 · 扬声器 | 独立开关，说话时麦位有绿色光环 |
| 💬 公屏 | 文字聊天、系统消息、点头像看名片 |
| 🎁 礼物 | 7 种礼物、选目标（个人/全房间）、数量、飘屏动画、金币扣减、魅力值增加 |
| 👑 VIP | VIP 码激活，金色皇冠标识 + 赠送 5000 金币 |
| 🎵 一起听歌 | **搜索服务器曲库**、全房间同步播放、暂停/下一首/歌单管理 |
| 📦 音乐缓存 | **上限 5GB**，边播边存、LRU 自动淘汰、可手动缓存和清空 |
| 🕘 最近听歌 | 自动记录，最多 100 条，显示播放次数与时间 |
| ⭐ 我的收藏 | 手动收藏/取消，最多 500 首 |

---

## 二、代码结构

```
voice-room/   ← 推到 GitHub 的仓库根目录
├── server.js                 服务端（已部署在腾讯云）
├── public/                   网页版前端
├── codemagic.yaml            Codemagic 云打包配置（必须在仓库根目录）
├── .github/workflows/build-ipa.yml  GitHub Actions 云打包配置（必须在仓库根目录）
├── .gitignore
└── ios-native/
    ├── VoiceRoom.xcodeproj/  Xcode 工程（可直接打开）
    └── VoiceRoom/
        ├── Package.swift         SPM 依赖声明（WebRTC）
        ├── Resources/
        │   ├── Info.plist        权限、ATS、后台音频
        │   └── Assets.xcassets   App 图标、主题色
        └── Sources/
            ├── App/              @main 入口 + 根路由
            ├── Models/           数据模型（用户/房间/成员/消息/礼物/歌曲）
            ├── Core/
            │   ├── Protocol.swift    WebSocket 消息协议（与服务端严格对应）
            │   ├── VRConnection.swift 长连接 + 心跳 + 指数退避重连
            │   ├── AppState.swift    全局状态中枢
            │   ├── VoiceEngine.swift WebRTC 语音引擎
            │   ├── MusicPlayer.swift 同步音乐播放器
            │   ├── MusicAPI.swift    曲库搜索接口
            │   ├── MusicCache.swift  5GB 音频缓存（LRU）
            │   └── MusicHistory.swift 最近听歌 + 收藏
            ├── UI/               设计系统 + 通用组件
            └── Features/
                ├── Auth/         登录页、服务器设置
                ├── Lobby/        大厅、创建房间、VIP 激活
                ├── Room/         房间页、礼物、成员、名片、听歌、房间设置
                └── Profile/      编辑名片
```

---

## 三、服务器（已部署 ✅）

服务器已经部署在你的腾讯云上，App 默认地址已配好，开箱即连：

| 项 | 值 |
|---|---|
| 地址 | `http://43.142.76.172:8125` |
| 大厅 | `http://43.142.76.172:8125/` |
| 管理后台 | `http://43.142.76.172:8125/admin.html` |
| 健康检查 | `http://43.142.76.172:8125/healthz` |

**服务器运维命令**（SSH 登录后）：

```bash
systemctl status voice-room    # 看运行状态
systemctl restart voice-room   # 重启服务
systemctl stop voice-room      # 停止
tail -f /var/log/voice-room.log # 跟踪日志
```

- 代码位置：`/opt/voice-room`，歌曲文件在 `/opt/voice-room/data/music/`
- 已配置 systemd：**开机自启 + 崩溃 5 秒后自动拉起**
- 环境：CentOS 7 + Node 16.20.2（CentOS 7 的 glibc 2.17 装不了 Node 18+，16 够用）

**换服务器时**改 `Sources/Core/Protocol.swift` 的 `defaultHost` 和 `useTLS`，或在 App 内「服务器设置」里直接填。

### 上传歌曲

打开管理后台（密码默认 `admin888`，**建议尽快改掉**：后台「系统设置」里改，或编辑 `/opt/voice-room/data/store.json` 里的 `adminPassword` 后 `systemctl restart voice-room`）。

在「音乐曲库」里拖拽上传 mp3，文件名写成 `歌手 - 歌名.mp3` 会自动拆好歌手和歌名。上传完 App 里就能搜到。

---

## 四、第二步：云打包出 .ipa

Windows 上没有 Xcode，必须用云端 Mac。**先决条件：把整个 `voice-room` 目录推到 GitHub 仓库**（注意：`tencent.py` 已在 .gitignore 里排除，不会被上传，它含服务器密码）。

推仓库最简单的方式（网页上传，不用装 git）：
1. GitHub 注册/登录 → 右上角 **+** → **New repository**
2. 名字随意（如 `voice-room`），选 **Public**（公开仓库 Actions 免费），Create
3. 仓库页点 "uploading an existing file" 链接
4. 把 `voice-room` 文件夹里的**内容**（不是文件夹本身）全选拖进去，Commit changes
5. 确认仓库里有 `codemagic.yaml`、`.github/`、`ios-native/` 即成功

两条路选一条。

### 方案 A：Codemagic（界面友好，推荐新手）

1. 注册 https://codemagic.io（可直接用 GitHub 账号登录）
2. 首次引导：「连接你的代码」选 **GitHub** → 授权 → 选择你的 `voice-room` 仓库
3. 项目类型选 **Other**（因为用自定义脚本）
4. 它会自动读到仓库根目录的 `codemagic.yaml`，直接点 **Start new build**
5. 约 10 分钟跑完，在 Artifacts 里下载 `VoiceRoom-unsigned.ipa`

免费额度：每月 500 分钟，够打几十次。

### 方案 B：GitHub Actions（公开仓库无限免费）

1. 代码推上去后，仓库 **Actions** 页面 → 左侧选 **Build unsigned IPA** → **Run workflow**
2. 约 12 分钟跑完，在页面底部 **Artifacts** 下载 `VoiceRoom-unsigned-ipa.zip`，解压得到 `.ipa`

免费额度：公开仓库无限；私有仓库每月 2000 分钟。

> 两个方案产出的都是**未签名 .ipa**。云端没你的证书，只有编译产物。

---

## 五、第三步：签名安装

你有 365 天永久签名渠道，这步用你自己的工具：

1. 把下载的 `VoiceRoom-unsigned.ipa` 拖进你的签名工具
2. 用你的证书重签
3. 安装到手机

**签名工具需要填的 Bundle ID**：`com.yourname.voiceroom`
（想改的话，在 `VoiceRoom.xcodeproj` 里改 `PRODUCT_BUNDLE_IDENTIFIER`，或者云打包前直接改 `project.pbxproj` 里的这一行）

**首次打开要授权**：App 会弹麦克风权限，选「允许」。不给的话只能听不能说。

---

## 六、常见问题

**Q：进房后听不到别人说话？**
检查三件事：① 麦克风权限给了没；② 有没有坐到麦位上（点空麦位）；③ 两台设备都装了 App 并进了同一房间。
P2P 语音需要双方都能互通，某些严格 NAT 的移动网络下可能连不上——这是 STUN-only 的固有限制。三个人小圈子一般没问题。

**Q：语音断断续续？**
WebRTC 会自动适应网络。如果一直很差，试试让房主换个网络环境（比如都连同一个 WiFi）。

**Q：搜不到歌？**
去 `admin.html` 看曲库是不是空的。曲库歌曲存在服务器的 `data/music/` 目录里。

**Q：缓存怎么算的？**
上限 5GB。播放在线歌曲时后台自动下载存本地，下次听同一首直接用本地文件。超过上限会自动删最旧的（保留到 4.5GB）。在听歌面板底部能看到已用空间，也能手动清空或单曲缓存。

**Q：切到后台音乐还在放吗？**
在，`Info.plist` 里开了 `audio` 后台模式。

**Q：想改成中文 App 名？**
`Info.plist` 里 `CFBundleDisplayName` 已经是「语音房」，改这里就行。

---

## 七、改代码后的重新打包

改完 Swift 代码，推送到 GitHub，Actions 会自动重新构建（配置了 push 触发）。
或者手动去 Actions 页面点 Run workflow。

---

## 八、技术选型说明

**为什么用 SPM 不用 CocoaPods？**
SPM 是 Xcode 原生支持的，云端构建机不需要额外装 pod，克隆下来直接 `xcodebuild` 就能编译，少一层出错的地方。

**为什么 WebRTC 用 stasel/WebRTC？**
Google 官方没有发布 SPM 包。`stasel/WebRTC` 是社区维护的官方二进制镜像，版本号对得上 Google 的 M 版本，是目前 iOS 上最省事的集成方式。

**为什么是 P2P mesh 不是 SFU？**
3 人房间，两两互联最多 3 条连接，完全够用，且不需要媒体服务器 = 不需要花钱。人多了（超过 6 人）才需要 SFU。
