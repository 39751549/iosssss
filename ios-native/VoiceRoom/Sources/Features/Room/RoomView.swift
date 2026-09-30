import SwiftUI

/// 房间主页面
///
/// 布局自上而下：顶栏 → 房主主位（0 号）→ 宾客麦位（1-8）→ 公屏 → 底部工具栏
struct RoomView: View {

    let state: VRRoomState

    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase

    @State private var chatInput = ""
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

    /// 长按麦位刚触发过（下麦 / 看名片）→ 这个触摸后续的"抬手点击"要丢掉。
    ///
    /// 麦位的 Button 和 LongPressGesture 是 `simultaneousGesture` 并联识别的关系：
    /// 长按到 0.42 秒时回调先触发，但手指抬起时 Button 的 action **照样**会触发一次。
    /// 结果是「长按自己下麦」会连带把名片弹出来、「长按别人看名片」会弹两次。
    /// 用这个标志在抬手那一下把点击吞掉。
    @State private var suppressSeatTap = false

    /// 麦位数量：0 = 房主专位，1-8 = 宾客（与服务端 9 座位一致）
    private let seatCount = 9

    var body: some View {
        ZStack {
            backgroundLayer

            // 房主是 VIP → 一层金色流光 + 闪烁星点（纯氛围层，不吃点击）
            if app.isVipRoom {
                GoldShimmerLayer()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

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
        // 礼物入口统一收进用户名片（点麦位/点公屏头像/成员列表 → 名片里的「送礼物」），
        // 底部工具栏不再放礼物按钮，所以这里也不需要礼物弹层
        .sheet(isPresented: $showMusic) {
            MusicSheet(state: state).environmentObject(app)
        }
        .sheet(isPresented: $showMembers) {
            // 名片由成员列表自己弹（嵌套 sheet），这里不再"收起列表再弹名片"——
            // 那种写法会让 iOS 的两个 sheet 互相打架，表现为名片无限打开又关闭
            MemberSheet(state: state, activity: app.activity).environmentObject(app)
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

                MusicBarContent(
                    song: song,
                    playing: state.playing,
                    modeIcon: state.mode.icon,
                    expanded: musicBarExpanded,
                    width: barW,
                    onTogglePlay: { app.musicControl(state.playing ? "pause" : "play") },
                    onOpenList: { showMusic = true },
                    onCycleMode: { app.cyclePlayMode() },
                    onCollapse: { setMusicBarExpanded(false) },
                    onExpand: { setMusicBarExpanded(true) }
                )
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

    private func setMusicBarExpanded(_ expanded: Bool) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
            musicBarExpanded = expanded
        }
        UserDefaults.standard.set(expanded, forKey: Self.musicBarExpandedKey)
    }

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

            // 房间信息：房间头像 + 两行（上房间名 · 下房间号 / 人数），透明底
            Button {
                showSettings = true
            } label: {
                HStack(spacing: 8) {
                    roomAvatarView

                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.room.name)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            // 房主是 VIP → 房间号走金色，和其他房间区分开
                            Text("ID \(state.room.no)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(state.room.ownerVip == true ? VRTheme.gold : .white.opacity(0.88))
                            Text("👥 \(state.members.count)")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white.opacity(0.88))
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
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

    /// 顶栏房间头像：房主上传过头像就显示头像，否则退回房间名首字。
    /// 房间名首字兜底是必要的 —— 绝大多数房间没有自定义头像，
    /// 留个空位比挤掉房间名更难看。
    private var roomAvatarView: some View {
        ZStack {
            if let url = roomAvatarURL {
                CachedAsyncImage(url: url, profile: .thumb) { phase in
                    if case let .success(img) = phase {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        roomAvatarFallback
                    }
                }
            } else {
                roomAvatarFallback
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1))
    }

    private var roomAvatarFallback: some View {
        ZStack {
            VRTheme.brandGradient
            Text(String(state.room.name.prefix(1)))
                .font(.system(size: 13, weight: .heavy))
                .foregroundColor(.white)
        }
    }

    private var roomAvatarURL: URL? {
        guard let a = state.room.avatar, !a.isEmpty else { return nil }
        return VRConfig.absoluteURL(for: a)
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

    /// 麦位区整体交给 `RoomStage`（见文件末尾）。
    ///
    /// 它是**唯一**订阅「谁在说话」的视图。说话状态一秒能变好几次（WebRTC 每 0.35 秒探一次音量），
    /// 如果让 RoomView 自己读，那每次有人开口闭口，整个房间页 —— 9 个麦位 + 公屏 + 悬浮条 ——
    /// 都要重算一遍 body。收敛到子视图之后，重算范围只剩这 9 个麦位。
    private var stage: some View {
        RoomStage(
            state: state,
            clientId: app.clientId,
            requesterId: app.songRequesterId,
            activity: app.activity,
            onTap: { handleSeatTap($0) },
            onLongPress: { handleSeatLongPress($0) }
        )
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
        // 刚长按过的这次触摸，抬手时会再触发一次 Button 的 action —— 直接吞掉。
        // 不吞的话：长按自己下麦会顺手把名片弹出来，长按别人会弹两次名片。
        if suppressSeatTap { return }
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

    /// 开始「这一次触摸不再当点击处理」的窗口。
    /// 0.5 秒足够覆盖"长按回调触发 → 手指抬起"这一段，又短到不会误伤下一次真实点击。
    private func markLongPressed() {
        suppressSeatTap = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            suppressSeatTap = false
        }
    }

    /// 长按自己的麦位 → 下麦（避免误触）
    private func handleSeatLongPress(_ seat: Int) {
        guard let m = state.member(atSeat: seat) else { return }
        markLongPressed()
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
                        ChatRow(message: m, ownerId: state.room.ownerId) {
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
        HStack(spacing: 9) {
            // 最左侧：公屏输入框（**透明**，不铺任何底板/玻璃块）
            chatField

            // 右侧三个圆形开关：扬声器 → 麦克风 → 音乐
            //
            // 这里刻意用 SF Symbol 而不是 emoji：emoji 里「静音」只有 🔇（一个划掉的喇叭），
            // 麦克风关掉时显示 🔇 的话，两个按钮就长得一模一样，用户根本分不清哪个是哪个。
            // SF Symbol 有 mic.slash 这种明确的「麦克风静音」，语义一眼可辨。
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
            barIcon("music.note",
                    // 用房间快照里的 playing，而不是去读 MusicPlayer 单例：
                    // 单例的 isPlaying 不订阅就不会触发刷新，而 position 每 0.4 秒变一次，
                    // 一旦在这里订阅它，整个房间页就得跟着每秒重算两次。
                    tint: state.playing ? VRTheme.brand : nil,
                    symbol: true) {
                showMusic = true
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, max(8, safeBottom))
    }

    /// 公屏输入框：**最左 + 完全透明**
    ///
    /// 透明之后的可读性靠"文字外发光"来兜（白色描边两层），
    /// 这和折叠态音乐图标用的是同一套办法 —— 不在背景上贴任何不透明色块，
    /// 但深浅背景都能看清。占位符是自己画的 Text，因为系统占位符的颜色改不动。
    private var chatField: some View {
        HStack(spacing: 4) {
            ZStack(alignment: .leading) {
                if chatInput.isEmpty {
                    Text("说点什么…")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundColor(VRTheme.text.opacity(0.5))
                        .vrTextGlow()
                        .allowsHitTesting(false)
                }
                TextField("", text: $chatInput)
                    .focused($chatFocused)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundColor(VRTheme.text)
                    .tint(VRTheme.brand)
                    .submitLabel(.send)
                    .onSubmit(sendChat)
                    .vrTextGlow()
            }

            if !chatInput.isEmpty {
                Button(action: sendChat) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(VRTheme.brand)
                        .vrTextGlow()
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
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

    // MARK: - 礼物特效 / VIP 发言飘屏

    private var giftOverlay: some View {
        RoomEffectLayer(animations: app.giftAnimations, marquees: app.chatMarquees)
    }
}

// MARK: - 麦位区（房主主位 + 宾客位）

/// 麦位区整体。
///
/// 单独成视图的唯一理由是「说话状态」：它挂在 `VoiceActivity` 上、变化非常频繁，
/// 把订阅范围收敛到这里之后，有人开口闭口就只需要重算这 9 个麦位，
/// 而不是整个房间页（公屏列表、悬浮音乐条、底部工具栏都不用跟着重算）。
struct RoomStage: View {

    let state: VRRoomState
    let clientId: String
    /// 正在播放的这首歌是谁点的（userId）
    let requesterId: String

    @ObservedObject var activity: VoiceActivity

    let onTap: (Int) -> Void
    let onLongPress: (Int) -> Void

    /// 0 = 房主专位，1-8 = 宾客（与服务端 9 座位一致）
    private let seatCount = 9

    var body: some View {
        VStack(spacing: 12) {
            // 房主主位（0 号专位，顶部居中）
            HostSeatCell(
                member: host,
                isHost: state.isOwner(host),
                speaking: speaking(host),
                requesting: isRequester(host),
                onTap: { onTap(0) },
                onLongPress: { onLongPress(0) }
            )

            // 宾客麦位 1-8（4 列 × 2 行）
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                      spacing: 12) {
                ForEach(1..<seatCount, id: \.self) { seat in
                    guestSeat(seat)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    /// 0 号主位。
    private var host: VRMember? { state.member(atSeat: 0) }

    /// 房主坐到 1-8 号麦位时，「房」字标得跟着他走，
    /// 不然房主一离开主位就"变成普通人"了。
    @ViewBuilder
    private func guestSeat(_ seat: Int) -> some View {
        let m = state.member(atSeat: seat)
        SeatCell(
            seat: seat,
            member: m,
            isHost: state.isOwner(m),
            speaking: speaking(m),
            requesting: isRequester(m),
            onTap: { onTap(seat) },
            onLongPress: { onLongPress(seat) }
        )
    }

    /// 成员直接传进来，省一次 `members.first { … }` 线性查找
    private func speaking(_ m: VRMember?) -> Bool {
        guard let m else { return false }
        return activity.speakingIds.contains(m.clientId)
    }

    /// 是不是「正在播放的这首歌的点歌人」。
    /// 用 userId 匹配而不是 clientId：同一个账号在快照里可能残留多条成员记录，clientId 会抖，userId 不会。
    private func isRequester(_ m: VRMember?) -> Bool {
        guard !requesterId.isEmpty, let m else { return false }
        return m.user.id == requesterId
    }
}

// MARK: - 麦位格子

struct SeatCell: View {
    let seat: Int
    let member: VRMember?
    /// 房主本人就坐在这个麦位（他离开主位换到 1-8 号时，名字旁的「房」标得跟着人走）
    var isHost: Bool = false
    let speaking: Bool
    /// 我就是当前这首歌的点歌人 → 金色音符光环
    var requesting: Bool = false
    let onTap: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 6) {
                ZStack {
                    // 两种光环互斥，避免同一张头像上叠两层光晕：点歌金环 > 说话绿环
                    if requesting {
                        RequestHalo(size: 62)
                    } else if speaking {
                        SpeakingHalo(size: 62, color: VRTheme.green)
                    }

                    if let member {
                        // 头像上的环只有两种：说话绿环、已戴的头像框。
                        // VIP 等级 / 房主身份都不再往头像上套环 —— 那些是"我是谁"，
                        // 交给名字表达（颜色 + 流光 + 名字后的「房」标）；
                        // 头像上的环只回答"此刻在不在说话"。
                        VRAvatarFull(user: member.user, size: 52,
                                     speaking: speaking,
                                     showNeutralRing: true)
                            // 静音不再往头像上贴标 —— 头像上什么都不压，
                            // 静音状态挪到下面名字胶囊里的小 🔇，头像变暗做辅助。
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

                // 静音标在名字前（头像上不放任何东西），没静音就完全不显示
                HStack(spacing: 3) {
                    if member?.muted == true {
                        Text("🔇")
                            .font(.system(size: 8.5))
                    }
                    VRNameText(name: member?.user.name ?? "空麦位",
                               vip: member?.user.vip == true,
                               vipLevel: member?.user.vipLevel ?? 0,
                               isHost: isHost,
                               size: 11,
                               weight: member == nil ? .regular : .medium,
                               baseColor: .white.opacity(member == nil ? 0.6 : 0.96))
                }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.26)))
                    .frame(maxWidth: .infinity)

                if requesting {
                    Text("🎵 点歌")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundColor(Color(hex: "5A3600"))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(VRTheme.goldGradient))
                }
                // 这里原来挂着「VIP11」徽章。现在等级数字只在名片里出现，
                // 身份改由名字的颜色/流光表达（见 VRNameTier）。
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

// MARK: - 点歌光环（金色，区别于说话的绿色）

/// 谁点的歌谁亮：金色音符光环 + 缓慢脉动。和说话绿环用同一套节奏，但颜色不同，
/// 一眼就能分清"这个人在说话"和"这首歌是他点的"。
struct RequestHalo: View {
    var size: CGFloat
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(VRTheme.gold.opacity(0.75), lineWidth: 2)
                .frame(width: size + 8, height: size + 8)
                .scaleEffect(pulse ? 1.07 : 0.97)
                .opacity(pulse ? 0.7 : 1)
            Circle()
                .fill(VRTheme.gold.opacity(0.16))
                .frame(width: size + 4, height: size + 4)
                .blur(radius: 6)
                .scaleEffect(pulse ? 1.05 : 0.99)
        }
        .shadow(color: VRTheme.gold.opacity(0.5), radius: 9)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
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
    /// 坐在 0 号位的确实是房主本人（按 ownerId 比出来，防历史残留记录占了主位）
    var isHost: Bool = true
    let speaking: Bool
    /// 我就是当前这首歌的点歌人 → 金色音符光环
    var requesting: Bool = false
    let onTap: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                ZStack(alignment: .top) {
                    // 点歌光环（金色）—— 两种光环互斥，避免同一张头像上套两层
                    if requesting {
                        RequestHalo(size: 74)
                    } else if speaking {
                        // 说话光环（柔和呼吸）
                        SpeakingHalo(size: 74, color: VRTheme.green)
                    }

                    // 头像（空位时为半透明虚线圆）
                    Group {
                        if let member {
                            // 头像上不再有房主金环 / VIP 分色环 / 皇冠：
                            // 那些跟"开不开麦"无关，静音挂在麦上也一直亮，
                            // 用户的感受就是"我没打开麦克风，为什么周围有光圈"。
                            VRAvatarFull(user: member.user, size: 62,
                                         speaking: speaking,
                                         showNeutralRing: true)
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
                    // 静音不往头像上贴标：头像变暗 + 名字行的小 🔇（见下方）
                }
                .frame(width: 76, height: 78)
                .padding(.top, 8)

                // 名字胶囊（带红色「房」字标）；透明底
                HStack(spacing: 4) {
                    // 空位挂着「房」标 —— 那是"这里是主位"的标识，不是"这个人是谁"的标识。
                    // 有人坐的时候「房」标由 VRNameText 挂在**名字后面**，
                    // 和麦位 / 公屏 / 成员列表位置一致（房主换到 1-8 号麦也是同一个样子）。
                    if member == nil {
                        Text("房")
                            .font(.system(size: 9.5, weight: .heavy))
                            .foregroundColor(.white)
                            .frame(width: 15, height: 15)
                            .background(Circle().fill(VRTheme.hostRed))
                    }
                    if member?.muted == true {
                        // 静音标在名字前（头像上不放任何东西），没静音就完全不显示
                        Text("🔇")
                            .font(.system(size: 9))
                    }
                    VRNameText(name: member?.user.name ?? "虚位以待",
                               vip: member?.user.vip == true,
                               vipLevel: member?.user.vipLevel ?? 0,
                               isHost: member != nil && isHost,
                               size: 11.5,
                               weight: .semibold,
                               baseColor: .white.opacity(member == nil ? 0.65 : 0.98))
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
    /// 房间房主的 userId —— 公屏上要认出哪条消息是房主发的，好给他挂「房」标
    var ownerId: String = ""
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
                        // 名字自带 VIP 特权色（金 / 紫流光 / 三色），不再贴「VIP」小标 ——
                        // 颜色本身就是身份标记，再叠一个标签只会把名字挤窄
                        VRNameText(name: message.name ?? "?",
                                   vip: message.vip == true,
                                   vipLevel: message.vip == true ? (message.vipLevel ?? 1) : 0,
                                   isHost: !ownerId.isEmpty && message.userId == ownerId,
                                   size: 11.5,
                                   weight: .semibold,
                                   baseColor: nameColor,
                                   onLight: true)
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

// MARK: - 房间上层特效层（礼物 + VIP 发言飘屏）

/// 房间最上层：礼物特效 + VIP 发言飘屏。整层不吃触摸。
///
/// 分区摆放，避免互相压住：
/// - 顶部 → VIP 发言飘屏（金色横幅）
/// - 底部 → 小/中档礼物横幅
/// - 全屏 → 大礼物爆炸（同时只播最新的一条）
struct RoomEffectLayer: View {
    let animations: [AppState.GiftAnimation]
    let marquees: [AppState.ChatMarquee]

    /// 小/中档礼物（走底部横幅；大礼物走全屏）
    private var banners: [AppState.GiftAnimation] {
        animations.filter { $0.tier != .big }
    }

    var body: some View {
        ZStack {
            // 大礼物：全屏爆炸。只取最新的一条，避免多个全屏动画同时跑
            if let big = animations.last(where: { $0.tier == .big }) {
                GiftBurstView(animation: big)
                    .id(big.id)
                    .transition(.opacity)
            }

            // 顶部：VIP 发言飘屏
            VStack(spacing: 8) {
                ForEach(marquees) { m in
                    VipChatMarqueeView(marquee: m)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 72)
            .padding(.horizontal, 14)

            // 底部：礼物横幅（从右滑入，落在底部工具栏上方）
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(banners) { a in
                    GiftBannerView(animation: a)
                }
            }
            .padding(.bottom, 108)
            .padding(.horizontal, 14)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 礼物横幅（小/中档）

/// 礼物横幅：头像 + 礼物 + 「谁送给谁」+ 连击数。
/// 中档（`tier == .mid`）做得更"重"一点：整条粉金渐变 + 更亮的描边与投影。
struct GiftBannerView: View {
    let animation: AppState.GiftAnimation

    @State private var offsetX: CGFloat = 380
    @State private var opacity: Double = 0
    /// 连击跳动
    @State private var pop = false

    private var isMid: Bool { animation.tier == .mid }

    /// 送礼人头像：飘屏里只带了头像路径，这里临时拼一个 user 给头像组件用
    private var fromUser: VRUser {
        VRUser(id: animation.comboKey, name: animation.fromName, avatar: animation.fromAvatar,
               gender: .secret, bio: "", coins: 0, charm: 0, vip: false, vipLevel: 0)
    }

    var body: some View {
        HStack(spacing: 9) {
            VRAvatarFull(user: fromUser, size: 30)

            Text(animation.emoji)
                .font(.system(size: isMid ? 26 : 22))

            VStack(alignment: .leading, spacing: 1) {
                Text("\(animation.fromName) → \(animation.toName)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(VRTheme.textDim)
                    .lineLimit(1)
                Text("\(animation.giftName) ×\(animation.count)")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(VRTheme.text)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if animation.count > 1 {
                Text("连击 \(animation.count)")
                    .font(.system(size: 10.5, weight: .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(VRTheme.pinkGradient))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: isMid
                            ? [VRTheme.pink.opacity(0.42), VRTheme.gold.opacity(0.34)]
                            : [VRTheme.pink.opacity(0.28), VRTheme.brand.opacity(0.20)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .background(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(VRTheme.pink.opacity(isMid ? 0.75 : 0.45), lineWidth: isMid ? 1.6 : 1)
        )
        .shadow(color: VRTheme.pink.opacity(isMid ? 0.45 : 0.28), radius: 12, y: 4)
        .scaleEffect(pop ? 1.06 : 1)
        .offset(x: offsetX)
        .opacity(opacity)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) {
                offsetX = 0
                opacity = 1
            }
        }
        // 连击累加时弹一下 —— "数字在涨"这件事要有反馈
        .onChange(of: animation.count) { _ in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.42)) { pop = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                withAnimation(.easeOut(duration: 0.2)) { pop = false }
            }
        }
        .transition(.asymmetric(
            insertion: .opacity,
            removal: .move(edge: .trailing).combined(with: .opacity)
        ))
    }
}

// MARK: - 大礼物全屏特效

/// 大礼物（单价 ≥ 10000 金币）：暖色光晕铺满 + 光环扩散 + 礼物旋转放大 + 连击大字。
struct GiftBurstView: View {
    let animation: AppState.GiftAnimation

    @State private var fly = false
    @State private var ring = false
    @State private var fade = false

    var body: some View {
        ZStack {
            // 暖色光晕
            RadialGradient(colors: [VRTheme.gold.opacity(0.50), VRTheme.pink.opacity(0.24), .clear],
                           center: .center, startRadius: 8, endRadius: ring ? 340 : 70)
                .opacity(fade ? 0 : 1)
                .ignoresSafeArea()

            // 扩散光环：一次扩散 + 淡出
            Circle()
                .strokeBorder(VRTheme.gold.opacity(0.6), lineWidth: 3)
                .frame(width: ring ? 520 : 70, height: ring ? 520 : 70)
                .opacity(ring ? 0 : 0.9)

            VStack(spacing: 12) {
                Text(animation.emoji)
                    .font(.system(size: 96))
                    .scaleEffect(fly ? 1 : 0.45)
                    .rotationEffect(.degrees(fly ? 0 : -22))
                    .offset(y: fly ? 0 : 130)
                    .shadow(color: VRTheme.gold.opacity(0.65), radius: 26)

                Text("\(animation.fromName) 送出 \(animation.giftName)")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(LinearGradient(colors: [VRTheme.pink, VRTheme.gold],
                                                      startPoint: .leading, endPoint: .trailing))
                    )
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                    .scaleEffect(fly ? 1 : 0.7)
                    .opacity(fly ? 1 : 0)

                if animation.count > 1 {
                    Text("×\(animation.count)")
                        .font(.system(size: 40, weight: .black))
                        .foregroundColor(VRTheme.gold)
                        .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
                        .scaleEffect(fly ? 1 : 0.3)
                        .opacity(fly ? 1 : 0)
                }
            }
            .opacity(fade ? 0 : 1)
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { fly = true }
            withAnimation(.easeOut(duration: 0.9)) { ring = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                withAnimation(.easeIn(duration: 0.7)) { fade = true }
            }
        }
    }
}

// MARK: - VIP 发言飘屏

/// VIP 在公屏说话时飘的金色横幅。普通用户不飘 —— 否则公屏一热闹就满屏都是。
struct VipChatMarqueeView: View {
    let marquee: AppState.ChatMarquee

    @State private var offsetX: CGFloat = 420
    @State private var opacity: Double = 0

    private var user: VRUser {
        VRUser(id: marquee.id, name: marquee.name, avatar: marquee.avatar,
               gender: .secret, bio: "", coins: 0, charm: 0, vip: true, vipLevel: marquee.vipLevel)
    }

    var body: some View {
        HStack(spacing: 9) {
            VRAvatarFull(user: user, size: 30)

            VStack(alignment: .leading, spacing: 2) {
                // 原来这里是一个「VIP11」金色胶囊。数字撤了 —— 飘屏本身就只服务 VIP，
                // 再报一遍等级是冗余；名字的三色流光才是真正"炫耀"的地方。
                VRNameText(name: marquee.name,
                           vip: true,
                           vipLevel: marquee.vipLevel,
                           size: 12.5,
                           weight: .bold)
                Text(marquee.text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            // 底色从"整条金色"换成深夜紫：金色名字 / 三色名字压在金色底上根本读不出来，
            // 深底才能把发光的名字衬出来。金边保留，VIP 的仪式感还在。
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color(hex: "2A1746").opacity(0.95),
                                            Color(hex: "5B2E8C").opacity(0.95),
                                            Color(hex: "2A1746").opacity(0.95)],
                                   startPoint: .leading, endPoint: .trailing)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color(hex: "FFE9A8"), lineWidth: 1.2)
        )
        .shadow(color: VRTheme.gold.opacity(0.5), radius: 12, y: 4)
        .offset(x: offsetX)
        .opacity(opacity)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                offsetX = 0
                opacity = 1
            }
        }
        .transition(.asymmetric(
            insertion: .identity,
            removal: .move(edge: .trailing).combined(with: .opacity)
        ))
    }
}

// MARK: - 悬浮音乐条（独立订阅播放进度）

/// 悬浮音乐条的内容。
///
/// 它是**唯一**订阅 `MusicPlayer` 的视图。播放进度每 0.4 秒推一次
/// （`addPeriodicTimeObserver(0.4)`）；如果让 RoomView 自己 `@ObservedObject` 它，
/// 整个房间页 —— 9 个麦位、公屏、底部工具栏 —— 每秒都要跟着重算两次 body。
/// 收进这个子视图之后，进度刷新只会重算这一根条子。
struct MusicBarContent: View {

    let song: VRSong
    let playing: Bool
    let modeIcon: String
    let expanded: Bool
    let width: CGFloat

    let onTogglePlay: () -> Void
    let onOpenList: () -> Void
    let onCycleMode: () -> Void
    let onCollapse: () -> Void
    let onExpand: () -> Void

    @ObservedObject private var player = MusicPlayer.shared

    var body: some View {
        Group {
            if expanded { expandedBar } else { collapsedBar }
        }
    }

    /// 展开形态：播放/暂停 · 歌名+进度+倒计时 · 播放模式 · 收起
    private var expandedBar: some View {
        HStack(spacing: 8) {
            Button(action: onTogglePlay) {
                Text(playing ? "⏸" : "▶️")
                    .font(.system(size: 15))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)

            // 点这里 → 打开完整歌单（"显示全部"）
            Button(action: onOpenList) {
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
            Button(action: onCycleMode) {
                Text(modeIcon)
                    .font(.system(size: 14))
                    .frame(width: 26, height: 30)
            }
            .buttonStyle(.plain)

            // 收起成一个圆图标
            Button(action: onCollapse) {
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
    private var collapsedBar: some View {
        ZStack {
            // 环形进度：折叠时唯一能看到播放位置的地方。
            // 只在真正播放时出现，且细到不会把图标"框"成一个按钮。
            if playing {
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
                .opacity(playing ? 1 : 0.5)
                // 白色外发光（画两层）＝ 给图标描个白边，亮背景上也不会糊掉
                .shadow(color: .white.opacity(0.95), radius: 2)
                .shadow(color: .white.opacity(0.75), radius: 5)
        }
        .frame(width: width, height: width)
        .contentShape(Circle())
        .onTapGesture { onExpand() }
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

// MARK: - 透明底上的文字可读性

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

    /// 白色外发光（两层）：给**没有底板**的文字/图标描一圈白边。
    ///
    /// 房间背景是照片/动图，明暗都可能有。透明文字只靠深色字在深背景上会糊掉，
    /// 叠两层白色光晕（近的一层当描边、远的一层当扩散）就深浅通吃。
    /// 折叠态的音乐图标用的也是这个思路。
    func vrTextGlow() -> some View {
        self
            .shadow(color: .white.opacity(0.95), radius: 1.6)
            .shadow(color: .white.opacity(0.7), radius: 4)
    }
}
