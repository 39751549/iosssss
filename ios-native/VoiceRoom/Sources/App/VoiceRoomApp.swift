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

                // 右上角透明悬浮音乐控件（有歌时显示）
                FloatingMusicWidget()
                    .zIndex(40)
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

/// 可拖动的圆形悬浮球：显示房间活跃状态，点击回到房间
struct FloatingRoomBall: View {
    @EnvironmentObject var app: AppState
    /// 说话状态单独订阅（它高频变化，不该挂在 AppState 上连累其余视图）
    @ObservedObject var activity: VoiceActivity

    @State private var position: CGPoint = CGPoint(x: UIScreen.main.bounds.width - 52,
                                                   y: UIScreen.main.bounds.height * 0.24)
    @State private var dragging = false

    private var speakingCount: Int {
        guard let st = app.roomState else { return 0 }
        return st.members.filter { activity.speakingIds.contains($0.clientId) }.count
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.72))
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(speakingCount > 0 ? VRTheme.green.opacity(0.8) : VRTheme.border, lineWidth: 1.4))
                .shadow(color: speakingCount > 0 ? VRTheme.green.opacity(0.35) : VRTheme.text.opacity(0.18), radius: 10, y: 3)

            VStack(spacing: 1) {
                Text("🎙️").font(.system(size: 21))
                Text("\(app.roomState?.members.count ?? 0)")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundColor(speakingCount > 0 ? VRTheme.green : VRTheme.textDim)
            }
        }
        .frame(width: 54, height: 54)
        .scaleEffect(dragging ? 1.08 : 1)
        .position(position)
        .gesture(
            DragGesture()
                .onChanged { g in
                    dragging = true
                    position = g.location
                }
                .onEnded { _ in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                        dragging = false
                        // 吸附到左右边缘
                        let w = UIScreen.main.bounds.width
                        position.x = position.x < w / 2 ? 40 : w - 40
                        position.y = min(max(position.y, 90), UIScreen.main.bounds.height - 120)
                    }
                }
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                app.roomMinimized = false
            }
        )
        .animation(.easeInOut(duration: 0.2), value: dragging)
    }
}

// MARK: - 悬浮音乐控件（右上角透明）

/// 房间有歌时显示：右侧悬浮的半透明唱片，可暂停/继续
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
