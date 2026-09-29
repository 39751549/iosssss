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
    /// 悬浮音乐条：位置 + 展开/折叠 都会持久化，下次进房原样恢复
    @State private var musicBarOffset: CGSize = .zero
    /// 拖动过程中的即时位移（松手自动归零）—— 关键：它和 musicBarOffset 分开。
    /// 以前只用 musicBarOffset 同时充当"已提交位置"和"本次拖动位移"，
    /// 而 DragGesture.translation 是相对**手指按下点**的，不是相对条的基准位置，
    /// 于是手指一按下去 translation≈0，条就瞬间跳回默认位置。
    @GestureState private var musicBarDrag: CGSize = .zero
    @State private var musicBarOffsetRestored = false
    /// 展开 = 完整控制条；折叠 = 一个圆图标
    @State private var musicBarExpanded = true

    private static let musicBarXKey = "vr_music_bar2_x"
    private static let musicBarYKey = "vr_music_bar2_y"
    private static let musicBarExpandedKey = "vr_music_bar_expanded"
    /// 折叠状态的直径
    private static let musicBarIconSize: CGFloat = 46
    /// 离屏幕边缘的安全距离
    private static let musicBarMargin: CGFloat = 10

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
        // 从左边缘往右滑 → 最小化（回到大厅的悬浮球，房间状态与语音连接都保持）
        .simultaneousGesture(backSwipeToMinimize)
        .onAppear {
            // 只在首次出现时恢复悬浮条的位置与展开状态（之后进房沿用用户当前的选择）
            if !musicBarOffsetRestored {
                musicBarOffsetRestored = true
                let d = UserDefaults.standard
                if d.object(forKey: Self.musicBarXKey) != nil || d.object(forKey: Self.musicBarYKey) != nil {
                    musicBarOffset = CGSize(width: d.double(forKey: Self.musicBarXKey),
                                            height: d.double(forKey: Self.musicBarYKey))
                }
                if d.object(forKey: Self.musicBarExpandedKey) != nil {
                    musicBarExpanded = d.bool(forKey: Self.musicBarExpandedKey)
                }
            }
        }
        .sheet(isPresented: $showGift) {
            GiftSheet(state: state, presetTarget: nil).environmentObject(app)
        }
        .sheet(isPresented: $showMusic) {
            MusicSheet(state: state).environmentObject(app)
        }
        .sheet(isPresented: $showMembers) {
            // 名片由成员列表自己弹（嵌套 sheet），这里不再"收起列表再弹名片"——
            // 那种写法会让 iOS 的两个 sheet 互相打架，表现为名片无限打开又关闭
            MemberSheet(state: state).environmentObject(app)
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

    /// 背景：自定义图/GIF 优先，否则用内置主题渐变。
    ///
    /// 图片来自 AppState（app.roomBackgroundImage），不是这里自己异步加载 ——
    /// 视图在"离开房间再进来 / 切后台回来"时会重建，self 持有的图片状态会丢，
    /// 于是只能先显示兜底渐变，看起来就像"背景被重置回默认主题"。
    /// 放到 AppState 之后，URL 不变就永远命中内存缓存，进出房间都是瞬时的。
    private var backgroundLayer: some View {
        ZStack {
            // 兜底渐变（内置主题 / 图片还没就位时可见）
            LinearGradient(colors: VRTheme.background(for: state.effectiveBackground),
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            // 自定义背景（含 GIF 动图）
            if let img = app.roomBackgroundImage {
                GIFImageView(image: img, contentMode: .scaleAspectFill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }

            // 光晕叠加（轻微，保证文字可读）
            RadialGradient(colors: VRTheme.glowColors(for: state.effectiveBackground),
                           center: .init(x: 0.25, y: 0.08),
                           startRadius: 0, endRadius: 380)
                .ignoresSafeArea()
                .opacity(0.55)
        }
        .animation(.easeInOut(duration: 0.35), value: app.roomBackgroundImage != nil)
        .animation(.easeInOut(duration: 0.35), value: state.effectiveBackground)
    }

    // MARK: - 悬浮音乐条（可拖动 / 可折叠成图标；默认贴右边缘）

    @ViewBuilder
    private var floatingMusicBar: some View {
        if let song = state.currentSong {
            GeometryReader { geo in
                let margin = Self.musicBarMargin
                let barW = musicBarWidth(in: geo.size)
                // 基准点 = 贴右边缘的位置；musicBarOffset 是在它基础上的位移
                let baseX = geo.size.width - barW / 2 - margin
                let baseY = Self.musicBarBaseY(in: geo.size)
                // 兜底约束：无论展开还是折叠，都保证整条在屏幕内
                let committed = clampMusicBar(musicBarOffset, barW: barW, in: geo.size)
                let live = CGSize(width: committed.width + musicBarDrag.width,
                                  height: committed.height + musicBarDrag.height)

                musicBarBody(song: song, width: barW)
                    .scaleEffect(musicBarDrag != .zero ? 1.04 : 1)
                    .position(x: baseX + live.width, y: baseY + live.height)
                    .gesture(
                        DragGesture(minimumDistance: 6)
                            .updating($musicBarDrag) { value, st, _ in st = value.translation }
                            .onEnded { value in
                                var o = CGSize(width: committed.width + value.translation.width,
                                               height: committed.height + value.translation.height)
                                // 松手吸附到最近的左右边缘（"贴紧"）
                                let centerX = baseX + o.width
                                let halfW = barW / 2
                                o.width = (centerX < geo.size.width / 2
                                           ? (margin + halfW)
                                           : (geo.size.width - margin - halfW)) - baseX
                                o = clampMusicBar(o, barW: barW, in: geo.size)
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                    musicBarOffset = o
                                }
                                let d = UserDefaults.standard
                                d.set(o.width, forKey: Self.musicBarXKey)
                                d.set(o.height, forKey: Self.musicBarYKey)
                            }
                    )
            }
            .zIndex(20)
        }
    }

    /// 展开时收窄（不占满整屏），折叠时是个圆
    private func musicBarWidth(in size: CGSize) -> CGFloat {
        guard musicBarExpanded else { return Self.musicBarIconSize }
        return min(max(size.width - 104, 172), 236)
    }

    /// 悬浮条默认高度位置（房主麦位下沿附近）
    private static func musicBarBaseY(in size: CGSize) -> CGFloat {
        size.height * 0.34
    }

    /// 把悬浮条约束在屏幕内。
    /// 注意基准点是"贴右边缘"，所以位移通常是 0 或负数（往左拖）。
    private func clampMusicBar(_ o: CGSize, barW: CGFloat, in size: CGSize) -> CGSize {
        let margin = Self.musicBarMargin
        let baseX = size.width - barW / 2 - margin
        let baseY = Self.musicBarBaseY(in: size)
        let half = barW / 2
        // 水平：整条不越出左右边界
        var minDX = margin + half - baseX
        var maxDX = size.width - margin - half - baseX
        if minDX > maxDX { swap(&minDX, &maxDX) }
        // 垂直：上方躲开顶栏，下方躲开底部工具栏
        var minDY = 56 + Self.musicBarIconSize / 2 - baseY
        var maxDY = size.height - 96 - Self.musicBarIconSize / 2 - baseY
        if minDY > maxDY { swap(&minDY, &maxDY) }
        return CGSize(width: min(max(o.width, minDX), maxDX),
                      height: min(max(o.height, minDY), maxDY))
    }

    @ViewBuilder
    private func musicBarBody(song: VRSong, width: CGFloat) -> some View {
        if musicBarExpanded {
            expandedMusicBar(song: song, width: width)
        } else {
            collapsedMusicBar(width: width)
        }
    }

    /// 展开形态：播放/暂停 · 歌名+进度+倒计时 · 播放模式 · 收起
    private func expandedMusicBar(song: VRSong, width: CGFloat) -> some View {
        HStack(spacing: 8) {
            Button {
                app.musicControl(state.playing ? "pause" : "play")
            } label: {
                Text(state.playing ? "⏸" : "▶️")
                    .font(.system(size: 15))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)

            // 点这里 → 打开完整歌单（"显示全部"）
            Button {
                showMusic = true
            } label: {
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 播放模式
            Button {
                app.cyclePlayMode()
            } label: {
                Text(state.mode.icon)
                    .font(.system(size: 14))
                    .frame(width: 26, height: 30)
            }
            .buttonStyle(.plain)

            // 收起成一个圆图标
            Button {
                setMusicBarExpanded(false)
            } label: {
                Text("⌄")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(VRTheme.textMute)
                    .frame(width: 24, height: 30)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: width)
        .musicBarChrome(corner: 15)
    }

    /// 折叠形态：一颗**透明的音符图标**（无底板，只靠图标本身 + 白色外发光保证可读），点一下展开
    ///
    /// 为什么不用白色圆形底板：折叠态本来就是个"最小占位"，画一块白底等于在房间背景上
    /// 贴了一张不透明的圆片，既挡背景又和展开态的玻璃条视觉不统一。
    /// 为什么不用白色图标：房间背景是明亮色系（天空蓝 / 樱花粉），白图标会糊进背景里。
    /// 所以用品牌蓝画图标，再叠两层白色外发光当作描边，深浅背景都能看清。
    private func collapsedMusicBar(width: CGFloat) -> some View {
        ZStack {
            // 环形进度：折叠时唯一能看到播放位置的地方。
            // 只在真正播放时出现，且细到不会把图标"框"成一个按钮。
            if state.playing {
                Circle()
                    .stroke(VRTheme.brand.opacity(0.16), lineWidth: 1.8)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, player.progressFraction)))
                    .stroke(VRTheme.brand, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: .white.opacity(0.9), radius: 2)
            }

            Image(systemName: "music.note")
                .font(.system(size: 21, weight: .bold))
                .foregroundColor(VRTheme.brand)
                // 暂停时压暗一点，一眼区分"在放"和"没放"，但不换图标形状
                .opacity(state.playing ? 1 : 0.5)
                // 白色外发光（画两层）＝ 给图标描个白边，亮背景上也不会糊掉
                .shadow(color: .white.opacity(0.95), radius: 2)
                .shadow(color: .white.opacity(0.75), radius: 5)
        }
        .frame(width: width, height: width)
        .contentShape(Circle())
        .onTapGesture { setMusicBarExpanded(true) }
    }

    private func setMusicBarExpanded(_ expanded: Bool) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
            musicBarExpanded = expanded
        }
        UserDefaults.standard.set(expanded, forKey: Self.musicBarExpandedKey)
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

    /// 打开某人名片。
    ///
    /// 两个要点：
    /// 1. **已经打开同一张名片就不重复赋值** —— 同一个触摸同时触发 Button 的动作和长按回调时，
    ///    重复赋值会让 sheet 重新走一遍 present/dismiss，看起来就是名片在闪。
    /// 2. 身份取 userId（见 VRCardTarget），同一账号的重复成员记录映射到同一张名片，
    ///    不会因为 clientId 抖动而把名片重开一遍。
    private func openCard(_ m: VRMember) {
        let t = VRCardTarget(member: m)
        guard cardUser?.id != t.id else { return }
        cardUser = t
    }

    /// 点头像 → 弹名片（不再下麦）；长按自己的麦位 → 下麦
    private func handleSeatTap(_ seat: Int) {
        // 0 号位是房主专位：非房主不能上；有人时一律看名片
        if seat == 0 {
            if let m = state.member(atSeat: 0) {
                openCard(m)                                 // 包括自己 → 看名片
            } else if app.isHost {
                app.takeSeat(0)                             // 空着且我是房主 → 上主位
            } else {
                app.showToast("0 号位是房主专位", kind: .error)
            }
            return
        }
        // 有人（含自己）→ 一律看名片
        if let m = state.member(atSeat: seat) {
            openCard(m)
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
            openCard(m)
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
                                openCard(member)
                            } else if let cid = m.userId,
                                      cid == app.userId, let me = app.me {
                                openCard(
                                    VRMember(clientId: app.clientId, user: me,
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
            // 左下角：扬声器（前）+ 麦克风（后）
            //
            // 这里刻意用 SF Symbol 而不是 emoji：emoji 里「静音」只有 🔇（一个划掉的喇叭），
            // 麦克风关掉时显示 🔇 的话，两个按钮就长得一模一样，用户根本分不清哪个是哪个。
            // SF Symbol 有 mic.slash 这种明确的「麦克风静音」，语义一眼可辨。
            HStack(spacing: 6) {
                barIcon(app.speakerEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                        tint: app.speakerEnabled ? VRTheme.brand : nil,
                        symbol: true) {
                    app.toggleSpeaker()
                }
                barIcon(app.micEnabled ? "mic.fill" : "mic.slash.fill",
                        tint: app.micEnabled ? VRTheme.green : nil,
                        symbol: true) {
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

    /// 底部栏图标：统一半透明玻璃底 + 白边，禁止不透明块状背景
    /// - Parameters:
    ///   - icon: emoji 文本，或 `symbol: true` 时的 SF Symbol 名
    ///   - symbol: 用 SF Symbol 渲染（音频开关这类"开/关"图标必须用它，emoji 没有对应的静音麦）
    private func barIcon(_ icon: String, tint: Color? = nil,
                         symbol: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if symbol {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(tint ?? .white)
                } else {
                    Text(icon)
                        .font(.system(size: 17))
                }
            }
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

    // MARK: - 左边缘右滑 → 最小化

    /// 从屏幕左边缘往右滑 = 最小化房间（等同系统返回手势的方向，但语义是"缩到悬浮球"，
    /// 不是退出房间 —— 语音连接和麦位都保持，点悬浮球原样回来）。
    ///
    /// 为什么用 `simultaneousGesture` 而不是在左边盖一条透明手势条：
    /// 盖条会挡住左侧按钮的点击热区 —— 顶栏的 ⌄ 和底部工具栏的扬声器都贴着左边缘
    /// （水平 padding 只有 12pt），一条 20pt 宽的透明条能吃掉它们左边一半的点击。
    /// `simultaneousGesture` 是"并联识别"，不会抢走子视图的点击；
    /// 再用 `startLocation.x` 把起手位置限定在左边缘 22pt 内，
    /// 就不会跟悬浮音乐条的拖动打架（音乐条默认贴右边缘，就算被拖到左边，
    /// 那种起手点也不在边缘区里）。
    ///
    /// 方向判定要求"横向位移明显大于纵向"，否则在公屏上竖直滑动也会被误当成返回手势。
    private var backSwipeToMinimize: some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { g in
                guard g.startLocation.x <= 22 else { return }
                let dx = g.translation.width
                let dy = g.translation.height
                guard dx > 56, abs(dx) > abs(dy) * 1.5 else { return }
                app.roomMinimized = true
            }
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
    /// 用 userId 而不是 clientId 作身份：
    /// 同一个账号可能因为残留连接在一份快照里出现两条记录（clientId 不同），
    /// 拿 clientId 当身份会让"同一张名片"被当成两张，反复 present/dismiss 闪屏。
    /// userId 是稳定的，重复记录自然收敛到同一张名片。
    var id: String { member.user.id.isEmpty ? member.clientId : member.user.id }
}

// MARK: - 悬浮音乐条的玻璃外壳（展开态用）

private extension View {
    /// 半透明毛玻璃 + 细描边 + 轻投影，保证在任何背景上都看得清
    func musicBarChrome(corner: CGFloat) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .fill(Color.white.opacity(0.55))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(VRTheme.brand.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: VRTheme.text.opacity(0.14), radius: 10, y: 4)
    }
}
