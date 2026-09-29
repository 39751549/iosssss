import SwiftUI

/// 房间主页面
///
/// 布局自上而下：顶栏 → 房主主位（0 号）→ 宾客麦位（1-8）→ 公屏 → 底部工具栏
struct RoomView: View {

    let state: VRRoomState

    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase

    @State private var chatInput = ""
    @State private var showGift = false
    @State private var showMusic = false
    @State private var showMembers = false
    @State private var showSettings = false
    @State private var showProfile = false
    @State private var cardUser: VRCardTarget?
    /// 悬浮音乐条位置（可拖动，默认在房主麦位与第一排之间）
    /// 位置会持久化：用户挪过一次，之后进房都停在原地
    @State private var musicBarOffset: CGSize = .zero
    @State private var musicBarOffsetRestored = false
    @State private var musicBarDragging = false

    private static let musicBarXKey = "vr_music_bar_x"
    private static let musicBarYKey = "vr_music_bar_y"

    @FocusState private var chatFocused: Bool

    /// 麦位数量：0 = 房主专位，1-8 = 宾客（与服务端 9 座位一致）
    private let seatCount = 9

    var body: some View {
        ZStack {
            backgroundLayer

            VStack(spacing: 0) {
                topBar
                stage
                chatArea
                bottomBar
            }

            // 音乐悬浮条：位于房主麦位与第一排麦位之间，可自由拖动
            floatingMusicBar

            giftOverlay
        }
        .onAppear {
            // 只在首次出现时恢复悬浮条位置（之后进房沿用用户挪到的位置）
            if !musicBarOffsetRestored {
                musicBarOffsetRestored = true
                let x = UserDefaults.standard.double(forKey: Self.musicBarXKey)
                let y = UserDefaults.standard.double(forKey: Self.musicBarYKey)
                if x != 0 || y != 0 { musicBarOffset = CGSize(width: x, height: y) }
            }
        }
        .sheet(isPresented: $showGift) {
            GiftSheet(state: state, presetTarget: nil).environmentObject(app)
        }
        .sheet(isPresented: $showMusic) {
            MusicSheet(state: state).environmentObject(app)
        }
        .sheet(isPresented: $showMembers) {
            MemberSheet(state: state, onOpenCard: { m in
                showMembers = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    cardUser = VRCardTarget(member: m)
                }
            }).environmentObject(app)
        }
        .sheet(isPresented: $showSettings) {
            RoomSettingsSheet(state: state).environmentObject(app)
        }
        .sheet(isPresented: $showProfile) {
            ProfileEditSheet().environmentObject(app)
        }
        .sheet(item: $cardUser) { t in
            UserCardSheet(member: t.member, state: state).environmentObject(app)
        }
        .onChange(of: scenePhase) { phase in
            // 从后台回到前台时，重新对齐一次音乐进度
            if phase == .active, let st = app.roomState {
                MusicPlayer.shared.sync(with: st, speakerOn: app.speakerEnabled)
            }
        }
    }

    // MARK: - 背景

    /// 背景：自定义图/GIF（本地缓存，URL 变化才重新下载）优先，否则用内置主题渐变
    private var backgroundLayer: some View {
        ZStack {
            // 兜底渐变（图片加载中/未设置时可见）
            LinearGradient(colors: VRTheme.background(for: state.room.background),
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            // 自定义背景（含 GIF 动图）；统一走 MediaCache，按 URL 缓存
            if let bgURL = absoluteBackgroundURL(state.effectiveBackground) {
                CachedAsyncImage(url: bgURL) { phase in
                    switch phase {
                    case .success(let img):
                        // 用 UIImageView 承载，GIF 会自动逐帧播放
                        GIFImageView(image: img, contentMode: .scaleAspectFill)
                            .ignoresSafeArea()
                            .transition(.opacity)
                    default:
                        EmptyView()
                    }
                }
            }

            // 光晕叠加（轻微，保证文字可读）
            RadialGradient(colors: VRTheme.glowColors(for: state.room.background),
                           center: .init(x: 0.25, y: 0.08),
                           startRadius: 0, endRadius: 380)
                .ignoresSafeArea()
                .opacity(0.55)
        }
        .animation(.easeInOut(duration: 0.45), value: state.effectiveBackground)
    }

    /// 背景相对路径 → 绝对 URL（/bg/xxx.gif → http://host/bg/xxx.gif）
    private func absoluteBackgroundURL(_ s: String) -> URL? {
        guard !s.isEmpty else { return nil }
        // 内置主题名（aurora/hearts）不是 URL，跳过
        if !s.hasPrefix("/") && !s.hasPrefix("http") { return nil }
        if s.hasPrefix("http") { return URL(string: s) }
        guard let base = VRConfig.baseURL else { return nil }
        return URL(string: s, relativeTo: base)
    }

    // MARK: - 悬浮音乐条（房主麦位与第一排之间，可拖动）

    @ViewBuilder
    private var floatingMusicBar: some View {
        if let song = state.currentSong {
            GeometryReader { geo in
                let baseY = geo.size.height * 0.30
                HStack(spacing: 9) {
                    // 播放/暂停
                    Button {
                        app.musicControl(state.playing ? "pause" : "play")
                    } label: {
                        Text(state.playing ? "⏸" : "▶️")
                            .font(.system(size: 15))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)

                    // 歌名 + 进度 + 倒计时
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(VRTheme.text)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color(hex: "27436B").opacity(0.16))
                                    Capsule()
                                        .fill(VRTheme.brandGradient)
                                        .frame(width: max(1.5, g.size.width * player.progressFraction))
                                }
                            }
                            .frame(height: 3)

                            Text("\(player.positionText)/\(player.durationText)")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(VRTheme.textMute)
                                .fixedSize()
                        }
                    }

                    // 播放模式
                    Button {
                        app.cyclePlayMode()
                    } label: {
                        Text(state.mode.icon).font(.system(size: 14))
                            .frame(width: 28, height: 32)
                    }
                    .buttonStyle(.plain)

                    // 拖动手柄
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(VRTheme.textMute)
                        .frame(width: 22, height: 32)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(width: min(geo.size.width - 28, 340))
                .background(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(Color.white.opacity(0.55))
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(VRTheme.brand.opacity(0.35), lineWidth: 1)
                )
                .shadow(color: VRTheme.text.opacity(0.14), radius: 10, y: 4)
                .scaleEffect(musicBarDragging ? 1.04 : 1)
                .position(x: geo.size.width / 2 + musicBarOffset.width,
                          y: baseY + musicBarOffset.height)
                .gesture(
                    DragGesture()
                        .onChanged { g in
                            musicBarDragging = true
                            musicBarOffset = g.translation
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                musicBarDragging = false
                                // 限制在屏幕内
                                let halfW = min(geo.size.width - 28, 340) / 2
                                let maxDX = geo.size.width / 2 - halfW - 6
                                musicBarOffset.width = min(max(musicBarOffset.width, -maxDX), maxDX)
                                musicBarOffset.height = min(max(musicBarOffset.height, -geo.size.height * 0.24),
                                                            geo.size.height * 0.42)
                                // 记住位置，下次进房不用再挪
                                UserDefaults.standard.set(musicBarOffset.width, forKey: Self.musicBarXKey)
                                UserDefaults.standard.set(musicBarOffset.height, forKey: Self.musicBarYKey)
                            }
                        }
                )
                .onTapGesture {
                    showMusic = true
                }
            }
            .allowsHitTesting(true)
            .zIndex(20)
        }
    }

    @ObservedObject private var player = MusicPlayer.shared

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 7) {
            // 最小化（回到大厅，语音与房间状态保持，可从悬浮球回来）
            Button {
                app.roomMinimized = true
            } label: {
                Text("⌄")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.black.opacity(0.28)))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)

            // 房间信息：两行（上房间名 · 下房间号），透明底
            Button {
                showSettings = true
            } label: {
                VStack(spacing: 1) {
                    Text(state.room.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("ID \(state.room.no)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.88))
                        Text("👥 \(state.members.count)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.88))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(Color.black.opacity(0.26))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            }
            .buttonStyle(.plain)

            // 成员
            topIcon("👥") { showMembers = true }

            // 房间设置（☰ 用白色实心图标，避免之前白色 UI 看不见）
            topIcon("⚙️") { showSettings = true }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    /// 顶栏半透明圆钮（深色底 + 白边，在任何背景上都可见）
    private func topIcon(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(icon)
                .font(.system(size: 16))
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.black.opacity(0.28)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 麦位区

    private var stage: some View {
        VStack(spacing: 12) {
            // 房主主位（0 号专位，顶部居中）
            HostSeatCell(
                member: state.member(atSeat: 0),
                isMine: state.member(atSeat: 0)?.clientId == app.clientId,
                speaking: isSpeaking(seat: 0),
                onTap: { handleSeatTap(0) },
                onLongPress: { handleSeatLongPress(0) }
            )

            // 宾客麦位 1-8（4 列 × 2 行）
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                      spacing: 12) {
                ForEach(1..<seatCount, id: \.self) { seat in
                    SeatCell(
                        seat: seat,
                        member: state.member(atSeat: seat),
                        isMine: state.member(atSeat: seat)?.clientId == app.clientId,
                        speaking: isSpeaking(seat: seat),
                        onTap: { handleSeatTap(seat) },
                        onLongPress: { handleSeatLongPress(seat) }
                    )
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private func isSpeaking(seat: Int) -> Bool {
        guard let m = state.member(atSeat: seat) else { return false }
        return app.speakingIds.contains(m.clientId)
    }

    /// 点头像 → 弹名片（不再下麦）；长按自己的麦位 → 下麦
    private func handleSeatTap(_ seat: Int) {
        // 0 号位是房主专位：非房主不能上；有人时一律看名片
        if seat == 0 {
            if let m = state.member(atSeat: 0) {
                cardUser = VRCardTarget(member: m)          // 包括自己 → 看名片
            } else if app.isHost {
                app.takeSeat(0)                             // 空着且我是房主 → 上主位
            } else {
                app.showToast("0 号位是房主专位", kind: .error)
            }
            return
        }
        // 有人（含自己）→ 一律看名片
        if let m = state.member(atSeat: seat) {
            cardUser = VRCardTarget(member: m)
            return
        }
        // 空位 → 上麦
        if app.myMember == nil || app.myMember?.seat != seat {
            app.takeSeat(seat)
        }
    }

    /// 长按自己的麦位 → 下麦（避免误触）
    private func handleSeatLongPress(_ seat: Int) {
        guard let m = state.member(atSeat: seat) else { return }
        if m.clientId == app.clientId {
            app.takeSeat(-1)
            app.showToast("已下麦")
        } else {
            cardUser = VRCardTarget(member: m)
        }
    }

    // MARK: - 公屏

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(app.messages) { m in
                        ChatRow(message: m) {
                            if let cid = m.userId,
                               let member = state.members.first(where: { $0.user.id == cid }) {
                                cardUser = VRCardTarget(member: member)
                            } else if let cid = m.userId,
                                      cid == app.userId, let me = app.me {
                                cardUser = VRCardTarget(
                                    member: VRMember(clientId: app.clientId, user: me,
                                                     seat: app.myMember?.seat ?? -1,
                                                     muted: false, joinedAt: 0)
                                )
                            }
                        }
                        .id(m.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .vrScrollHidden()
            .onChange(of: app.messages.count) { _ in
                if let last = app.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let last = app.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - 底部工具栏

    private var bottomBar: some View {
        HStack(spacing: 8) {
            // 左下角：扬声器（前）+ 麦克风（后），半透明图标
            HStack(spacing: 6) {
                barIcon(app.speakerEnabled ? "🔊" : "🔇",
                        tint: app.speakerEnabled ? VRTheme.brand : nil) {
                    app.toggleSpeaker()
                }
                barIcon(micIcon, tint: app.micEnabled ? VRTheme.green : nil) {
                    app.toggleMic()
                }
            }

            // 礼物
            barIcon("🎁") { showGift = true }

            // 输入框
            HStack(spacing: 6) {
                TextField("说点什么…", text: $chatInput)
                    .focused($chatFocused)
                    .font(.system(size: 14))
                    .foregroundColor(VRTheme.text)
                    .submitLabel(.send)
                    .onSubmit(sendChat)

                if !chatInput.isEmpty {
                    Button(action: sendChat) {
                        Text("➤")
                            .font(.system(size: 15))
                            .foregroundColor(VRTheme.brand2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 13)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.42))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
            )

            // 听歌
            barIcon("🎵", tint: MusicPlayer.shared.isPlaying ? VRTheme.brand : nil) {
                showMusic = true
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, max(8, safeBottom))
    }

    private var micIcon: String {
        if !app.micEnabled { return "🔇" }
        return "🎤"
    }

    /// 底部栏图标：统一半透明玻璃底 + 白边，禁止不透明块状背景
    private func barIcon(_ icon: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(icon)
                .font(.system(size: 17))
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tint?.opacity(0.30) ?? Color.black.opacity(0.26))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(tint?.opacity(0.85) ?? Color.white.opacity(0.32), lineWidth: 1.2)
                )
        }
        .buttonStyle(.plain)
    }

    private var safeBottom: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.bottom ?? 0
    }

    private func sendChat() {
        let t = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        app.sendChat(t)
        chatInput = ""
    }

    // MARK: - 礼物飘屏

    private var giftOverlay: some View {
        VStack {
            ForEach(app.giftAnimations) { anim in
                GiftFlyingView(animation: anim)
            }
            Spacer()
        }
        .padding(.top, 76)
        .padding(.horizontal, 16)
        .allowsHitTesting(false)
    }
}

// MARK: - 麦位格子

struct SeatCell: View {
    let seat: Int
    let member: VRMember?
    let isMine: Bool
    let speaking: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    // 说话光环：柔和呼吸光圈（说话时出现，不说时消失）
                    if speaking {
                        SpeakingHalo(size: 62, color: VRTheme.green)
                    }

                    if let member {
                        VRAvatarFull(user: member.user, size: 52)
                            .overlay(
                                Circle().strokeBorder(
                                    isMine ? VRTheme.brand : Color.white.opacity(0.55),
                                    lineWidth: isMine ? 2 : 1.4
                                )
                            )
                            .overlay(alignment: .bottomTrailing) {
                                if member.muted {
                                    ZStack {
                                        Circle().fill(Color.black.opacity(0.72)).frame(width: 19, height: 19)
                                        Text("🔇").font(.system(size: 9))
                                    }
                                    .offset(x: 2, y: 2)
                                }
                            }
                            .opacity(member.muted ? 0.72 : 1)
                    } else {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.16))
                                .frame(width: 52, height: 52)
                            Circle()
                                .strokeBorder(Color.white.opacity(0.5),
                                              style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                                .frame(width: 52, height: 52)
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white.opacity(0.85))
                        }
                    }
                }
                .frame(width: 62, height: 62)

                Text(member?.user.name ?? "空麦位")
                    .font(.system(size: 11, weight: member == nil ? .regular : .medium))
                    .foregroundColor(.white.opacity(member == nil ? 0.6 : 0.96))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.26)))
                    .frame(maxWidth: .infinity)

                if let member, member.user.vip {
                    VRBadge(kind: .vip, text: "VIP\(member.user.vipLevel)")
                        .scaleEffect(0.85)
                }
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.42).onEnded { _ in
                if member != nil { onLongPress() }
            }
        )
    }
}

// MARK: - 说话光圈（柔和呼吸效果）

/// 说话时出现的柔和光圈：不刺眼，只让人一眼看出谁在说话
struct SpeakingHalo: View {
    var size: CGFloat
    var color: Color
    @State private var pulse = false

    var body: some View {
        ZStack {
            // 外圈扩散光
            Circle()
                .stroke(color.opacity(0.55), lineWidth: 2)
                .frame(width: size + 8, height: size + 8)
                .scaleEffect(pulse ? 1.06 : 0.96)
                .opacity(pulse ? 0.75 : 1)
            // 内圈柔光
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: size + 4, height: size + 4)
                .blur(radius: 6)
                .scaleEffect(pulse ? 1.04 : 0.98)
        }
        .shadow(color: color.opacity(0.45), radius: 8)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - 房主主位（0 号专位）

struct HostSeatCell: View {
    let member: VRMember?
    let isMine: Bool
    let speaking: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                ZStack(alignment: .top) {
                    // 说话光环（柔和呼吸）
                    if speaking {
                        SpeakingHalo(size: 74, color: VRTheme.green)
                    }

                    // 头像（空位时为半透明虚线圆）
                    Group {
                        if let member {
                            VRAvatarFull(user: member.user, size: 62)
                                .opacity(member.muted ? 0.72 : 1)
                        } else {
                            ZStack {
                                Circle().fill(Color.white.opacity(0.16))
                                Circle().strokeBorder(Color.white.opacity(0.55),
                                                      style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                                Image(systemName: "plus")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.white.opacity(0.85))
                            }
                            .frame(width: 62, height: 62)
                        }
                    }
                    .frame(width: 70, height: 70)
                    .overlay(
                        Circle().strokeBorder(
                            isMine ? VRTheme.brand : Color.white.opacity(0.55),
                            lineWidth: isMine ? 2 : 1.2
                        )
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if let member, member.muted {
                            ZStack {
                                Circle().fill(Color.black.opacity(0.72)).frame(width: 20, height: 20)
                                Text("🔇").font(.system(size: 9))
                            }
                            .offset(x: 2, y: 2)
                        }
                    }
                    // 房主皇冠
                    .overlay(alignment: .top) {
                        Text("👑")
                            .font(.system(size: 15))
                            .offset(y: -12)
                    }
                }
                .frame(width: 76, height: 78)
                .padding(.top, 8)

                // 名字胶囊（带红色"房"字标）；透明底
                HStack(spacing: 4) {
                    Text("房")
                        .font(.system(size: 9.5, weight: .heavy))
                        .foregroundColor(.white)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(Color(hex: "E0344C")))
                    Text(member?.user.name ?? "虚位以待")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white.opacity(member == nil ? 0.65 : 0.98))
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(Color.black.opacity(0.28)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.42).onEnded { _ in
                if member != nil { onLongPress() }
            }
        )
    }
}

// MARK: - 公屏消息行

struct ChatRow: View {
    let message: VRChatMessage
    let onAvatarTap: () -> Void

    var body: some View {
        if message.isSystem {
            Text(message.text)
                .font(.system(size: 11.5))
                .foregroundColor(VRTheme.textMute)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.6)))
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            HStack(alignment: .top, spacing: 8) {
                Button(action: onAvatarTap) {
                    VRAvatarFull(user: tempUser, size: 26)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(message.name ?? "?")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(nameColor)
                        if message.vip == true {
                            VRBadge(kind: .vip, text: "VIP").scaleEffect(0.8)
                        }
                        Text(message.timeText)
                            .font(.system(size: 9.5))
                            .foregroundColor(VRTheme.textMute)
                    }

                    Text(message.text)
                        .font(.system(size: 13.5))
                        .foregroundColor(VRTheme.text)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.75))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(VRTheme.border, lineWidth: 1)
                        )
                        .textSelection(.enabled)
                }

                Spacer(minLength: 24)
            }
        }
    }

    private var tempUser: VRUser {
        VRUser(id: message.userId ?? "?",
               name: message.name ?? "?",
               avatar: message.avatar ?? "",
               gender: .secret, bio: "",
               coins: 0, charm: 0,
               vip: message.vip == true, vipLevel: message.vipLevel ?? 0)
    }

    private var nameColor: Color {
        if message.vip == true { return VRTheme.gold }
        return VRTheme.brand2
    }
}

// MARK: - 礼物飘屏动画

struct GiftFlyingView: View {
    let animation: AppState.GiftAnimation

    @State private var offsetX: CGFloat = 320
    @State private var opacity: Double = 0

    var body: some View {
        HStack(spacing: 10) {
            Text(animation.emoji)
                .font(.system(size: 30))

            VStack(alignment: .leading, spacing: 1) {
                Text(animation.text)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(VRTheme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(colors: [VRTheme.pink.opacity(0.34), VRTheme.brand.opacity(0.24)],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .background(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(VRTheme.pink.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: VRTheme.pink.opacity(0.3), radius: 12, y: 4)
        .offset(x: offsetX)
        .opacity(opacity)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
                offsetX = 0
                opacity = 1
            }
        }
        .transition(.asymmetric(
            insertion: .opacity,
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
    }
}

// MARK: - 名片弹窗的目标包装（用于 sheet(item:)）

struct VRCardTarget: Identifiable {
    let member: VRMember
    var id: String { member.clientId }
}
