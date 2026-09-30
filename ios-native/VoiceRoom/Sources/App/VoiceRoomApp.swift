import SwiftUI

@main
struct VoiceRoomApp: App {

    @StateObject private var app = AppState()
    @StateObject private var serverStore = ServerStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(serverStore)
                .preferredColorScheme(.light)
                .onAppear { app.start() }
        }
    }
}

/// 根视图：根据登录状态切换页面（房间可最小化为悬浮球）
struct RootView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var serverStore: ServerStore
    /// 前后台切换：切后台时系统可能掐掉 WebSocket（进程挂起收不到失败回调），
    /// 回前台必须主动探测/重连，否则会一直卡在"正在连接"。
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            VRTheme.bg.ignoresSafeArea()

            if app.inRoom, let state = app.roomState, !app.roomMinimized {
                RoomView(state: state)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if app.isLoggedIn {
                LobbyView()
                    .transition(.opacity)

                // 房间最小化 → 圆形悬浮球（可拖动，点击回到房间）
                if app.inRoom && app.roomMinimized {
                    FloatingRoomBall(activity: app.activity)
                        .zIndex(50)
                }

                // 右上角透明悬浮音乐控件（有歌时显示）。
                // 房间最小化成悬浮球后不再显示：两个控件都挤在右上角会叠在一起，
                // 悬浮球点一下就能回房间，不需要在球上再挂一层播放控制。
                if !app.roomMinimized {
                    FloatingMusicWidget()
                        .zIndex(40)
                }
            } else {
                LoginView()
                    .transition(.opacity)
            }

            // 全局 Toast
            if let toast = app.toast {
                VStack {
                    VRToastView(message: toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer()
                }
                .padding(.top, 8)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: toast.id)
                .zIndex(999)
            }

            // 连接状态提示
            if case .failed = app.connection.status, !app.isLoggedIn {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        ProgressView().tint(VRTheme.brand).scaleEffect(0.8)
                        Text("正在连接服务器…")
                            .font(.system(size: 13))
                            .foregroundColor(VRTheme.textDim)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Color.white.opacity(0.9)))
                    .padding(.bottom, 30)
                }
            }
        }
        .animation(.easeInOut(duration: 0.28), value: app.inRoom)
        .animation(.easeInOut(duration: 0.28), value: app.roomMinimized)
        .animation(.easeInOut(duration: 0.28), value: app.isLoggedIn)
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:     app.appDidBecomeActive()
            case .background: app.appDidEnterBackground()
            default:          break
            }
        }
    }
}

// MARK: - 房间悬浮球（最小化）

/// 可拖动的房间悬浮胶囊：房间缩略图 + 房间名 + 在线/说话状态，点击回到房间。
///
/// 三个坑（都踩过）：
/// 1) `DragGesture()` 默认走 `.local` 坐标空间 —— 那是相对这个胶囊自己的 0~宽，
///    直接把它赋给 `.position()`，拖动瞬间球会跳到屏幕左上角。必须显式用 `.global`。
/// 2) 原来拖动结束会强制吸附到左右边缘。用户要的是"拖到哪就停在哪"，
///    所以改成只做边界约束、不吸附。
/// 3) 位置按屏幕宽高的比例存进 UserDefaults，重开 App 还在原地；
///    存绝对坐标的话换机型 / 系统缩放到一半就跑到屏幕外了。
struct FloatingRoomBall: View {
    @EnvironmentObject var app: AppState
    /// 说话状态单独订阅（它高频变化，不该挂在 AppState 上连累其余视图）
    @ObservedObject var activity: VoiceActivity

    @AppStorage("vr.ballXRatio") private var xRatio: Double = -1
    @AppStorage("vr.ballYRatio") private var yRatio: Double = -1

    @State private var position: CGPoint = .zero
    @State private var dragging = false
    /// 位置算好之前先不显示，否则会在左上角闪一帧再跳到目标位置
    @State private var ready = false

    /// 胶囊尺寸。边界计算必须基于它 —— 原来按圆形半径估的，改成胶囊后就不准了。
    private let ballSize = CGSize(width: 154, height: 48)
    private let edgeInset: CGFloat = 6

    private var speakingCount: Int {
        guard let st = app.roomState else { return 0 }
        return st.members.filter { activity.speakingIds.contains($0.clientId) }.count
    }

    private var roomName: String {
        let n = app.roomState?.room.name ?? ""
        return n.isEmpty ? "语音房" : n
    }

    private var roomNoText: String {
        let n = app.roomState?.room.no ?? ""
        return n.isEmpty ? "" : "ID \(n)"
    }

    /// 悬浮球的房间图标：优先房间头像（房主上传的"门面"），
    /// 其次房间背景的缩略图，都没有才退回麦克风符号。
    private var iconURL: URL? {
        if let a = app.roomState?.room.avatar, !a.isEmpty,
           let u = VRConfig.absoluteURL(for: a) { return u }
        if let bg = app.roomState?.effectiveBackground, !bg.isEmpty {
            return VRConfig.absoluteURL(for: bg)
        }
        return nil
    }

    private var windowInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets ?? .zero
    }

    var body: some View {
        HStack(spacing: 8) {
            // 房间图标：用房间背景的圆形缩略图，一眼认出是哪个房；
            // 没设背景就退回麦克风符号。
            ZStack {
                if iconURL != nil {
                    CachedAsyncImage(url: iconURL, profile: .thumb) { phase in
                        if case .success(let img) = phase {
                            Image(uiImage: img).resizable().scaledToFill()
                        } else {
                            iconFallback
                        }
                    }
                } else {
                    iconFallback
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(
                speakingCount > 0 ? VRTheme.green.opacity(0.95) : Color.white.opacity(0.9),
                lineWidth: 1.6))
            .shadow(color: (speakingCount > 0 ? VRTheme.green : Color.black).opacity(0.2), radius: 4, y: 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(roomName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(VRTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 5) {
                    Text(roomNoText)
                        .font(.system(size: 9))
                        .foregroundColor(app.roomState?.room.ownerVip == true
                                         ? Color(hex: "D98A0B") : VRTheme.textMute)
                        .lineLimit(1)

                    HStack(spacing: 1) {
                        Text("🎙").font(.system(size: 8))
                        Text("\(app.roomState?.members.count ?? 0)")
                            .font(.system(size: 9.5, weight: .heavy))
                            .foregroundColor(speakingCount > 0 ? VRTheme.green : VRTheme.textDim)
                    }

                    if speakingCount > 0 {
                        Text("说话中")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(VRTheme.green))
                    }
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .frame(width: ballSize.width, height: ballSize.height)
        .background(
            RoundedRectangle(cornerRadius: ballSize.height / 2, style: .continuous)
                .fill(Color.white.opacity(0.66))
                .background(.ultraThinMaterial,
                            in: RoundedRectangle(cornerRadius: ballSize.height / 2, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ballSize.height / 2, style: .continuous)
                .strokeBorder(speakingCount > 0 ? VRTheme.green.opacity(0.85) : VRTheme.border,
                              lineWidth: 1.4)
        )
        .shadow(color: (speakingCount > 0 ? VRTheme.green : VRTheme.text).opacity(0.22), radius: 12, y: 4)
        .scaleEffect(dragging ? 1.05 : 1)
        .position(position)
        .opacity(ready ? 1 : 0)
        .onAppear {
            layout()
            ready = true
        }
        .gesture(
            DragGesture(coordinateSpace: .global)
                .onChanged { g in
                    dragging = true
                    position = clamped(g.location)
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        dragging = false
                        position = clamped(position)
                    }
                    saveRatio(position)
                }
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                app.roomMinimized = false
            }
        )
        .animation(.easeInOut(duration: 0.2), value: dragging)
    }

    private var iconFallback: some View {
        ZStack {
            VRTheme.brandGradient
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    /// 首次出现时摆好位置：拖过就用存下来的比例还原，没拖过就落在右上角
    private func layout() {
        let size = UIScreen.main.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if xRatio >= 0, yRatio >= 0 {
            position = clamped(CGPoint(x: CGFloat(xRatio) * size.width,
                                       y: CGFloat(yRatio) * size.height))
        } else {
            position = clamped(CGPoint(x: size.width - ballSize.width / 2 - 8,
                                       y: size.height * 0.22))
        }
    }

    /// 只做「别跑出屏幕」的约束，**不吸附边缘** —— 用户拖到哪就停在哪
    private func clamped(_ p: CGPoint) -> CGPoint {
        let size = UIScreen.main.bounds.size
        let insets = windowInsets
        let hw = ballSize.width / 2, hh = ballSize.height / 2
        let topLimit = max(insets.top, 20) + edgeInset + hh
        let bottomLimit = size.height - max(insets.bottom, 20) - edgeInset - hh
        return CGPoint(
            x: min(max(p.x, hw + edgeInset), max(size.width - hw - edgeInset, hw + edgeInset)),
            y: min(max(p.y, topLimit), max(bottomLimit, topLimit))
        )
    }

    private func saveRatio(_ p: CGPoint) {
        let size = UIScreen.main.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        xRatio = Double(p.x / size.width)
        yRatio = Double(p.y / size.height)
    }
}

// MARK: - 悬浮音乐控件（右上角透明）

/// 有歌在放时显示的半透明唱片，可暂停/继续。
/// 注意：房间最小化成悬浮球时**不显示** —— 两个控件都挤在右上角会叠在一起，
/// 而且悬浮球点一下就能回房间，不需要在球上再挂一层播放控制。
struct FloatingMusicWidget: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var player = MusicPlayer.shared

    var body: some View {
        if !player.currentId.isEmpty {
            VStack(alignment: .trailing, spacing: 5) {
                Button {
                    player.togglePlayPause()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.75))
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(player.isPlaying ? VRTheme.brand.opacity(0.7) : VRTheme.border, lineWidth: 1.2))
                        Text(player.isPlaying ? "⏸" : "▶️")
                            .font(.system(size: 15))
                    }
                    .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)

                Text(player.currentTitle)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(VRTheme.textDim)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.85)))
                    .frame(width: 88)
                    .opacity(0.9)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, 10)
            .padding(.top, 90)
            .allowsHitTesting(true)
        }
    }
}
