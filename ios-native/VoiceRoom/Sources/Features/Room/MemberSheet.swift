import SwiftUI

/// 房间成员列表
struct MemberSheet: View {

    let state: VRRoomState

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var giftTarget: VRMember?
    /// 名片（点成员行）—— 挂在成员列表自己身上，避免"收起列表 + 弹出名片"两个 sheet 打架
    @State private var cardTarget: VRCardTarget?

    private var micMembers: [VRMember] {
        state.members.filter { $0.seat >= 0 }.sorted { $0.seat < $1.seat }
    }

    private var listeners: [VRMember] {
        state.members.filter { $0.seat < 0 }
    }

    var body: some View {
        ZStack {
            VRTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text("👥 房间成员")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(VRTheme.text)
                    Text("\(state.members.count)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(VRTheme.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(VRTheme.green.opacity(0.16)))
                    Spacer()
                    Button { dismiss() } label: {
                        Text("✕")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(VRTheme.textMute)
                            .frame(width: 30, height: 30)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !micMembers.isEmpty {
                            section(title: "🎙 麦上", members: micMembers)
                        }
                        if !listeners.isEmpty {
                            section(title: "💬 听众", members: listeners)
                        }
                        if state.members.isEmpty {
                            Text("房间里还没有人")
                                .font(.system(size: 13))
                                .foregroundColor(VRTheme.textMute)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                .vrScrollHidden()
            }
        }
        .vrSheet(medium: true, large: true)
        .sheet(item: $giftTarget) { m in
            GiftSheet(state: state, presetTarget: m.clientId).environmentObject(app)
        }
        // 名片挂在成员列表内部：列表不收起，也就不会出现"一个 sheet 收起、另一个弹出"的打架
        .sheet(item: $cardTarget) { t in
            UserCardSheet(member: t.member, state: state).environmentObject(app)
        }
    }

    private func section(title: String, members: [VRMember]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(VRTheme.textDim)

            ForEach(members) { m in
                memberRow(m)
            }
        }
    }

    private func memberRow(_ m: VRMember) -> some View {
        let isHost = m.clientId == state.hostClientId
        let isSpeaking = app.speakingIds.contains(m.clientId)

        return HStack(spacing: 11) {
            VRAvatarFull(user: m.user, size: 44)
                .overlay(
                    Circle().strokeBorder(isSpeaking ? VRTheme.green : .clear, lineWidth: 2)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(m.user.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(VRTheme.text)
                        .lineLimit(1)
                    if m.user.vip { VRBadge(kind: .vip, text: "VIP\(m.user.vipLevel)") }
                    if isHost { VRBadge(kind: .host, text: "房主") }
                    if m.clientId == app.clientId { VRBadge(kind: .green, text: "我") }
                }

                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        VRGenderIcon(gender: m.user.gender)
                        Text(m.user.gender.label)
                    }
                    Text("💰 \(shortNum(m.user.coins))")
                    Text("💖 \(shortNum(m.user.charm))")
                    if m.muted { Text("🔇") }
                }
                .font(.system(size: 10.5))
                .foregroundColor(VRTheme.textMute)
            }

            Spacer()

            Button {
                giftTarget = m
            } label: {
                Text("🎁")
                    .font(.system(size: 15))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(VRTheme.pink.opacity(0.18)))
                    .overlay(Circle().strokeBorder(VRTheme.pink.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color(hex: "27436B").opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(VRTheme.border, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            // 关键：**不要**先 dismiss 再让外面弹名片。
            // iOS 一个视图同时只能有一个 sheet；成员列表还在收起动画里时让名片弹出来，
            // 系统会把名片立刻收掉，而绑定值依旧非空 → 于是"打开-关闭-打开-关闭"无限循环。
            // 正确做法是把名片挂在成员列表自己身上（嵌套 sheet），两个弹层各归各的。
            cardTarget = VRCardTarget(member: m)
        }
    }
}

// MARK: - 用户名片弹窗

struct UserCardSheet: View {

    let member: VRMember
    let state: VRRoomState

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showGift = false

    private var isMe: Bool { member.clientId == app.clientId }

    var body: some View {
        ZStack {
            VRTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部渐变头图
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: VRTheme.background(for: state.room.background),
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .frame(height: 128)

                    VRAvatarFull(user: member.user, size: 82)
                        .overlay(
                            Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 3)
                        )
                        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
                        .offset(y: 40)

                    HStack {
                        Spacer()
                        Button { dismiss() } label: {
                            Text("✕")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Color.black.opacity(0.35)))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 86)
                }
                .frame(height: 128)

                ScrollView {
                    VStack(spacing: 14) {
                        // 名字
                        VStack(spacing: 6) {
                            HStack(spacing: 6) {
                                Text(member.user.name)
                                    .font(.system(size: 19, weight: .bold))
                                    .foregroundColor(VRTheme.text)
                                if member.user.vip {
                                    VRBadge(kind: .vip, text: "👑 VIP\(member.user.vipLevel)")
                                }
                            }
                            HStack(spacing: 7) {
                                HStack(spacing: 2) {
                                    VRGenderIcon(gender: member.user.gender)
                                    Text(member.user.gender.label)
                                }
                                .font(.system(size: 12))
                                .foregroundColor(VRTheme.textDim)
                                if member.clientId == state.hostClientId {
                                    VRBadge(kind: .host, text: "房主")
                                }
                                if member.seat >= 0 {
                                    VRBadge(kind: .green, text: "\(member.seat + 1) 号麦")
                                }
                            }
                        }
                        .padding(.top, 30)

                        if !member.user.bio.isEmpty {
                            Text(member.user.bio)
                                .font(.system(size: 13))
                                .foregroundColor(VRTheme.textDim)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                        }

                        // 数据
                        HStack(spacing: 10) {
                            statBox(title: "💰 金币", value: shortNum(member.user.coins), color: VRTheme.gold)
                            statBox(title: "💖 魅力值", value: shortNum(member.user.charm), color: VRTheme.pink)
                            statBox(title: "👑 会员",
                                    value: member.user.vip ? "VIP\(member.user.vipLevel)" : "普通",
                                    color: member.user.vip ? VRTheme.gold : VRTheme.textDim)
                        }
                        .padding(.horizontal, 20)

                        // VIP 等级与刷礼物挂钩：展示晋升进度
                        vipProgress

                        // 操作
                        VStack(spacing: 10) {
                            if !isMe {
                                Button("🎁 送礼物") { showGift = true }
                                    .buttonStyle(VRButtonStyle(kind: .pink, fullWidth: true))
                            }
                            Button(isMe ? "✏️ 编辑我的名片" : "✉️ 打个招呼") {
                                if isMe {
                                    dismiss()
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        app.showToast("请在大厅「编辑名片」中修改")
                                    }
                                } else {
                                    app.sendChat("@\(member.user.name) 你好呀 👋")
                                    dismiss()
                                }
                            }
                            .buttonStyle(VRButtonStyle(fullWidth: true))
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 30)
                    }
                }
                .vrScrollHidden()
            }
        }
        .vrSheet()
        .sheet(isPresented: $showGift) {
            GiftSheet(state: state, presetTarget: member.clientId).environmentObject(app)
        }
    }

    private func statBox(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 16, weight: .heavy))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(title)
                .font(.system(size: 10.5))
                .foregroundColor(VRTheme.textDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(hex: "27436B").opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(VRTheme.border, lineWidth: 1)
        )
    }

    /// VIP 晋升进度：魅力值越高等级越高（与刷礼物挂钩）
    @ViewBuilder
    private var vipProgress: some View {
        let charm = member.user.charm
        let cur = VIPCharmStairs.level(for: charm)
        let next = VIPCharmStairs.nextThreshold(for: charm)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("👑 VIP 等级")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(VRTheme.textDim)
                Spacer()
                Text(member.user.vip ? "VIP\(member.user.vipLevel)" : "未激活")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(member.user.vip ? VRTheme.gold : VRTheme.textMute)
            }

            if let nxt = next {
                GeometryReader { geo in
                    let prev = VIPCharmStairs.threshold(for: cur)
                    let span = max(1, nxt - prev)
                    let done = min(1, max(0, Double(charm - prev) / Double(span)))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(hex: "27436B").opacity(0.12))
                        Capsule()
                            .fill(VRTheme.goldGradient)
                            .frame(width: max(3, geo.size.width * done))
                    }
                }
                .frame(height: 6)

                Text("再获 \(shortNum(max(0, nxt - charm))) 魅力值可升 VIP\(cur + 1)（刷礼物即涨魅力值）")
                    .font(.system(size: 10.5))
                    .foregroundColor(VRTheme.textMute)
            } else {
                Text("已达最高 VIP 等级 🎉")
                    .font(.system(size: 10.5))
                    .foregroundColor(VRTheme.gold)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(VRTheme.gold.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(VRTheme.gold.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 20)
    }
}

// MARK: - VIP 魅力值阶梯（与服务端 VIP_CHARM_STAIRS 保持一致）

enum VIPCharmStairs {
    /// 与服务端 server.js 的 VIP_CHARM_STAIRS 严格对应
    static let stairs: [Int] = [100, 500, 2000, 8000, 30000, 100000,
                                300000, 1000000, 3000000, 10000000, 30000000]

    /// 当前魅力值对应的 VIP 等级
    static func level(for charm: Int) -> Int {
        var lv = 0
        for (i, t) in stairs.enumerated() where charm >= t { lv = i + 1 }
        return lv
    }

    /// 该等级的魅力值门槛
    static func threshold(for level: Int) -> Int {
        guard level >= 1, level <= stairs.count else { return 0 }
        return stairs[level - 1]
    }

    /// 升到下一级所需魅力值（已满级返回 nil）
    static func nextThreshold(for charm: Int) -> Int? {
        for t in stairs where charm < t { return t }
        return nil
    }
}
