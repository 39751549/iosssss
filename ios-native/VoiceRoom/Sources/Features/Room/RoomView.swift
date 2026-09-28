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

            giftOverlay
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

    private var backgroundLayer: some View {
        LinearGradient(colors: VRTheme.background(for: state.room.background),
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .overlay(
                RadialGradient(colors: VRTheme.glowColors(for: state.room.background),
                               center: .init(x: 0.25, y: 0.08),
                               startRadius: 0, endRadius: 380)
                    .ignoresSafeArea()
            )
            .animation(.easeInOut(duration: 0.45), value: state.room.background)
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 7) {
            // 最小化（回到大厅，语音与房间状态保持，可从悬浮球回来）
            Button {
                app.roomMinimized = true
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(VRTheme.text)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.3)))
            }
            .buttonStyle(.plain)

            // 房间信息胶囊
            Button {
                showSettings = true
            } label: {
                HStack(spacing: 8) {
                    Text(state.room.no)
                        .font(.system(size: 12.5, weight: .heavy, design: .monospaced))
                        .foregroundColor(VRTheme.gold)
                    Text(state.room.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(VRTheme.text)
                        .lineLimit(1)
                    HStack(spacing: 2) {
                        Text("👥").font(.system(size: 10))
                        Text("\(state.members.count)")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundColor(VRTheme.green)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(Color.black.opacity(0.32)))
                .overlay(Capsule().strokeBorder(VRTheme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)

            // 扬声器
            VRIconButton(icon: app.speakerEnabled ? "🔊" : "🔇",
                         active: app.speakerEnabled,
                         size: 36) { app.toggleSpeaker() }

            // 成员
            VRIconButton(icon: "👥", size: 36) { showMembers = true }

            // 房间设置（⋮：房间名 / 背景 / 离开 / 解散）
            VRIconButton(icon: "⋮", size: 36) { showSettings = true }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
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
                onLongPress: {
                    if let m = state.member(atSeat: 0) {
                        cardUser = VRCardTarget(member: m)
                    }
                }
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
                        onLongPress: {
                            if let m = state.member(atSeat: seat) {
                                cardUser = VRCardTarget(member: m)
                            }
                        }
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

    private func handleSeatTap(_ seat: Int) {
        // 0 号位是房主专位，非房主不允许上
        if seat == 0 {
            if let m = state.member(atSeat: 0) {
                if m.clientId == app.clientId {
                    app.takeSeat(-1)
                    app.showToast("已下麦")
                } else {
                    cardUser = VRCardTarget(member: m)
                }
            } else if app.isHost {
                app.takeSeat(0)
            } else {
                app.showToast("0 号位是房主专位", kind: .error)
            }
            return
        }
        guard let my = app.myMember else {
            app.takeSeat(seat)
            return
        }
        // 点自己的麦位 → 下麦；点空位 → 上麦；点别人的 → 看名片
        if my.seat == seat {
            app.takeSeat(-1)
            app.showToast("已下麦")
        } else if state.member(atSeat: seat) == nil {
            app.takeSeat(seat)
        } else if let m = state.member(atSeat: seat) {
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
            // 麦克风
            Button {
                app.toggleMic()
            } label: {
                Text(app.micEnabled ? "🎤" : "🔇")
                    .font(.system(size: 18))
                    .frame(width: 44, height: 44)
                    .background(
                        Group {
                            if app.micEnabled { VRTheme.green.opacity(0.28) }
                            else { Color.black.opacity(0.36) }
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(app.micEnabled ? VRTheme.green.opacity(0.7) : VRTheme.border, lineWidth: 1.2)
                    )
            }
            .buttonStyle(.plain)

            // 礼物
            VRIconButton(icon: "🎁", size: 44) { showGift = true }

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
                    .fill(Color.black.opacity(0.36))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(VRTheme.border, lineWidth: 1)
            )

            // 听歌
            VRIconButton(icon: "🎵", active: MusicPlayer.shared.isPlaying, size: 44) { showMusic = true }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, max(8, safeBottom))
        .background(
            LinearGradient(colors: [.clear, Color.black.opacity(0.32)],
                           startPoint: .top, endPoint: .bottom)
        )
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
                    // 说话光环
                    if speaking {
                        Circle()
                            .stroke(VRTheme.green, lineWidth: 2.5)
                            .frame(width: 60, height: 60)
                            .shadow(color: VRTheme.green.opacity(0.7), radius: 10)
                            .scaleEffect(1.02)
                            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                                       value: speaking)
                    }

                    if let member {
                        VRAvatarFull(user: member.user, size: 52)
                            .overlay(
                                Circle().strokeBorder(
                                    isMine ? VRTheme.brand : Color.white.opacity(0.28),
                                    lineWidth: isMine ? 2 : 1.4
                                )
                            )
                            .overlay(alignment: .bottomTrailing) {
                                if member.muted {
                                    ZStack {
                                        Circle().fill(Color(hex: "2A1220")).frame(width: 19, height: 19)
                                        Text("🔇").font(.system(size: 9))
                                    }
                                    .offset(x: 2, y: 2)
                                }
                            }
                            .opacity(member.muted ? 0.72 : 1)
                    } else {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.07))
                                .frame(width: 52, height: 52)
                            Circle()
                                .strokeBorder(Color.white.opacity(0.2),
                                              style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                                .frame(width: 52, height: 52)
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(VRTheme.textMute)
                        }
                    }
                }
                .frame(width: 62, height: 62)

                Text(member?.user.name ?? "空麦位")
                    .font(.system(size: 11, weight: member == nil ? .regular : .medium))
                    .foregroundColor(member == nil ? VRTheme.textMute : VRTheme.text)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)

                if let member, member.user.vip {
                    VRBadge(kind: .vip, text: "VIP")
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
                    // 说话光环
                    if speaking {
                        Circle()
                            .stroke(VRTheme.green, lineWidth: 2.5)
                            .frame(width: 74, height: 74)
                            .shadow(color: VRTheme.green.opacity(0.7), radius: 10)
                            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                                       value: speaking)
                    }

                    // 全透明圆形（空位）/ 头像
                    Group {
                        if let member {
                            VRAvatarFull(user: member.user, size: 62)
                                .opacity(member.muted ? 0.72 : 1)
                        } else {
                            ZStack {
                                Circle().fill(Color.white.opacity(0.08))
                                Circle().strokeBorder(Color.white.opacity(0.22),
                                                      style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                                Image(systemName: "plus")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(VRTheme.textMute)
                            }
                            .frame(width: 62, height: 62)
                        }
                    }
                    .frame(width: 70, height: 70)
                    .overlay(
                        Circle().strokeBorder(
                            isMine ? VRTheme.brand : Color.white.opacity(0.3),
                            lineWidth: isMine ? 2 : 1.2
                        )
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if let member, member.muted {
                            ZStack {
                                Circle().fill(Color(hex: "2A1220")).frame(width: 20, height: 20)
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

                // 名字胶囊（带红色"房"字标）
                HStack(spacing: 4) {
                    Text("房")
                        .font(.system(size: 9.5, weight: .heavy))
                        .foregroundColor(.white)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(Color(hex: "E0344C")))
                    Text(member?.user.name ?? "虚位以待")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(member == nil ? VRTheme.textMute : VRTheme.text)
                        .lineLimit(1)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(Color.black.opacity(0.32)))
                .overlay(Capsule().strokeBorder(VRTheme.border, lineWidth: 1))
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
                .background(Capsule().fill(Color.black.opacity(0.24)))
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
                                .fill(Color.black.opacity(0.3))
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
