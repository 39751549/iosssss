import SwiftUI

/// 房间成员列表
struct MemberSheet: View {

    let state: VRRoomState
    let onOpenCard: (VRMember) -> Void

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var giftTarget: VRMember?

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
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { onOpenCard(m) }
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
                            statBox(title: "🎙 状态",
                                    value: member.muted ? "静音" : (member.seat >= 0 ? "在麦" : "听众"),
                                    color: member.muted ? VRTheme.textDim : VRTheme.green)
                        }
                        .padding(.horizontal, 20)

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
}
