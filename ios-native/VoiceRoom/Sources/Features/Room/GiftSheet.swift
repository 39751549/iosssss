import SwiftUI

/// 送礼物面板
struct GiftSheet: View {

    let state: VRRoomState
    /// 从名片/成员列表进来时预选收礼人
    var presetTarget: String?

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedGiftId: String?
    @State private var count = 1
    @State private var targetClientId: String?

    private var gifts: [VRGift] { app.giftList }

    private var selectedGift: VRGift? {
        gifts.first { $0.id == selectedGiftId }
    }

    private var cost: Int { (selectedGift?.price ?? 0) * count }

    private var canAfford: Bool { (app.me?.coins ?? 0) >= cost }

    var body: some View {
        ZStack {
            VRTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                // 头部
                HStack {
                    Text("🎁 送礼物")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(VRTheme.text)
                    Spacer()
                    HStack(spacing: 4) {
                        Text("💰")
                        Text(shortNum(app.me?.coins ?? 0))
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundColor(VRTheme.gold)
                    }
                    Button {
                        dismiss()
                    } label: {
                        Text("✕")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(VRTheme.textMute)
                            .frame(width: 30, height: 30)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        targetPicker
                        giftPicker
                        countPicker

                        Button {
                            send()
                        } label: {
                            Text(selectedGift == nil
                                 ? "请先选一个礼物"
                                 : "送出 · \(cost) 金币")
                        }
                        .buttonStyle(VRButtonStyle(kind: .pink, fullWidth: true))
                        .disabled(selectedGift == nil || !canAfford)
                        .opacity(selectedGift == nil || !canAfford ? 0.45 : 1)

                        if !canAfford && selectedGift != nil {
                            Text("金币不足，还差 \(shortNum(cost - (app.me?.coins ?? 0))) 金币")
                                .font(.system(size: 12.5))
                                .foregroundColor(VRTheme.red)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }

                        Text("金币是纯娱乐虚拟币，不涉及任何充值。不够时可在管理后台给自己发放。")
                            .font(.system(size: 11.5))
                            .foregroundColor(VRTheme.textMute)
                            .padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(hex: "27436B").opacity(0.05))
                            )
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                .vrScrollHidden()
            }
        }
        .vrSheet()
        .onAppear(perform: setup)
    }

    // MARK: - 送给谁

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("送给谁")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(VRTheme.textDim)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    // 全房间
                    targetChip(cid: nil, name: "全房间", emoji: "🏠")

                    ForEach(state.members) { m in
                        Button {
                            targetClientId = m.clientId
                        } label: {
                            VStack(spacing: 5) {
                                VRAvatarFull(user: m.user, size: 42,
                                             isMine: m.clientId == app.clientId,
                                             vipLevel: m.user.vip ? m.user.vipLevel : 0,
                                             showNeutralRing: true)
                                    .overlay(
                                        Circle().strokeBorder(
                                            targetClientId == m.clientId ? VRTheme.pink : .clear,
                                            lineWidth: 2.5
                                        )
                                    )
                                if targetClientId == m.clientId {
                                    // 选中态用品牌粉覆盖，选中反馈优先于 VIP 特权色
                                    Text(m.user.name)
                                        .font(.system(size: 10.5))
                                        .foregroundColor(VRTheme.pink)
                                        .lineLimit(1)
                                        .frame(width: 52)
                                } else {
                                    VRNameText(name: m.user.name,
                                               vip: m.user.vip,
                                               vipLevel: m.user.vipLevel,
                                               size: 10.5,
                                               weight: .regular,
                                               baseColor: VRTheme.textDim,
                                               onLight: true)
                                        .frame(width: 52)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func targetChip(cid: String?, name: String, emoji: String) -> some View {
        Button {
            targetClientId = cid
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(VRTheme.brandGradient)
                        .frame(width: 42, height: 42)
                    Text(emoji).font(.system(size: 19))
                }
                .overlay(
                    Circle().strokeBorder(targetClientId == cid ? VRTheme.pink : .clear, lineWidth: 2.5)
                )
                Text(name)
                    .font(.system(size: 10.5))
                    .foregroundColor(targetClientId == cid ? VRTheme.pink : VRTheme.textDim)
                    .frame(width: 52)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 选礼物

    private var giftPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("选礼物")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(VRTheme.textDim)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3),
                      spacing: 9) {
                ForEach(gifts) { g in
                    Button {
                        selectedGiftId = g.id
                    } label: {
                        VStack(spacing: 5) {
                            Text(g.emoji).font(.system(size: 27))
                            Text(g.name)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundColor(VRTheme.text)
                                .lineLimit(1)
                            Text("\(g.price) 金币")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundColor(VRTheme.gold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(selectedGiftId == g.id
                                      ? VRTheme.pink.opacity(0.18)
                                      : Color(hex: "27436B").opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(selectedGiftId == g.id ? VRTheme.pink : VRTheme.border,
                                              lineWidth: selectedGiftId == g.id ? 1.8 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 数量

    private var countPicker: some View {
        HStack(spacing: 18) {
            Button {
                count = max(1, count - 1)
            } label: {
                Text("−")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(VRTheme.text)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color(hex: "27436B").opacity(0.1)))
            }
            .buttonStyle(.plain)

            Text("\(count)")
                .font(.system(size: 21, weight: .heavy))
                .foregroundColor(VRTheme.text)
                .frame(minWidth: 52)

            Button {
                count = min(99, count + 1)
            } label: {
                Text("＋")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(VRTheme.text)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color(hex: "27436B").opacity(0.1)))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
    }

    // MARK: - 逻辑

    private func setup() {
        if selectedGiftId == nil { selectedGiftId = gifts.first?.id }
        // presetTarget 为空 = 没指定收礼人 → 保持「全房间」（targetClientId 本身就是 nil）
        if let presetTarget, !presetTarget.isEmpty {
            targetClientId = presetTarget
        }
    }

    private func send() {
        guard let g = selectedGift else { return }
        guard (app.me?.coins ?? 0) >= cost else {
            app.showToast("金币不足", kind: .error)
            return
        }
        // ⚠️ 这里**不能**再写 `targetClientId ?? state.members.first?.clientId`。
        //
        // 「全房间」在界面上就是"没选具体某个人"（targetClientId == nil）。以前那行兜底
        // 会把"全房间"悄悄替换成"房间里的第一个人" —— 用户点的是全房、金币照扣，
        // 结果只有一个人涨魅力值，其他人什么都没收到。
        // 现在直接把空串透传给服务端，由服务端理解成"房间里除自己之外每个人各收一份"。
        let target = targetClientId ?? ""
        app.sendGift(giftId: g.id, count: count, toClientId: target)
        app.showToast("已送出 \(g.emoji) \(g.name) ×\(count)", kind: .success)
        dismiss()
    }
}
