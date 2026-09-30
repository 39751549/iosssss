import SwiftUI

/// 房间成员列表
struct MemberSheet: View {

    let state: VRRoomState
    /// 说话状态单独订阅（高频变化，不挂在 AppState 上）
    @ObservedObject var activity: VoiceActivity

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
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
        // 礼物入口统一收进名片：点成员行 → 名片里有「送礼物」。
        // 列表行上不再单独放礼物按钮，避免"同一个动作两个入口"，也省掉一次多余的弹层。
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
        let isHost = state.isOwner(m)
        let isSpeaking = activity.speakingIds.contains(m.clientId)

        return HStack(spacing: 11) {
            // 头像框（房主金环 / VIP 分色环 / 说话绿环）由头像组件统一画，
            // 所以这里不再自己叠一圈 strokeBorder —— 那样会出现两圈环压在一起
            VRAvatarFull(user: m.user, size: 44,
                         isHost: isHost,
                         isMine: m.clientId == app.clientId,
                         speaking: isSpeaking,
                         vipLevel: m.user.vip ? m.user.vipLevel : 0)

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

            // 只留一个"展开"指示，礼物入口在名片里（点这一行就进去了）
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(VRTheme.textMute)
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

/// 名片的两种形态：
/// - `compact`：小名片（封面 + 头像/名字/等级 + 「查看完整主页」「送礼物」两个大圆按钮）
/// - `full`：完整主页（在小名片下方继续展开数据、VIP 晋升进度、签名与次级操作）
enum VRCardMode { case compact, full }

/// 切换 sheet 高度档位：compact ↔ medium，full ↔ large。
///
/// 为什么用「撑大同一张 sheet」而不是再叠一层 sheet：
/// 名片本身可能已经是第 2 层弹层（房间 → 成员列表 → 名片），
/// 再往上叠第 3 层时，iOS 会因为「同一个时刻只允许一个 presentation 在动画中」而把新的丢掉，
/// 表现就是「点了没反应」或者一闪而过。改成切换 detent 就没有这个问题。
private struct VRCardDetentModifier: ViewModifier {

    @Binding var mode: VRCardMode

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.0, *) {
            content
                // 小名片用**固定高度**而不是 .medium：
                // .medium 是"半屏"，在 iPhone SE 这种小屏上只有 ~333pt，
                // 而封面 + 两个大圆按钮至少要 373pt，会把按钮裁掉一截。
                // 高度按屏高自适应（见 compactHeight），保证两个圆按钮完整露出、不用户滚。
                .presentationDetents([.height(Self.compactHeight), .large], selection: detent)
                // 不显示系统把手：名片是自定义视觉（封面铺到顶），
                // 一条灰色横杠压在封面上很突兀；收起/展开交给右上的箭头和 ✕。
                .presentationDragIndicator(.hidden)
        } else {
            content
        }
    }

    /// 小名片高度：兜底 373pt（内容自然高度）保证按钮不被裁，
    /// 大屏上再放宽一点，看着不局促。
    static var compactHeight: CGFloat {
        min(420, max(376, UIScreen.main.bounds.height * 0.46))
    }

    /// `PresentationDetent` 本身是 iOS 16+ 的类型，
    /// 所以**用到它的属性也要标 `@available`** —— 只在 body 里写 `if #available` 不够：
    /// 编译器是逐个声明检查可用性的，一个 iOS 16 类型出现在未标注的属性签名里就直接报错。
    ///
    /// getter 必须返回「**真的在 detents 集合里**的那个档位」：
    /// 这里以前返回的是 `.medium`，而集合里只有 `.height(378)` 和 `.large` ——
    /// selection 指向一个不存在的档位时，系统会按"就近吸附"猜一个，
    /// 表现就是高度偶尔自己跳（小屏上尤其明显）。
    @available(iOS 16.0, *)
    private var detent: Binding<PresentationDetent> {
        Binding(
            get: { mode == .full ? PresentationDetent.large : PresentationDetent.height(Self.compactHeight) },
            set: { mode = ($0 == PresentationDetent.large) ? .full : .compact }
        )
    }
}

struct UserCardSheet: View {

    let member: VRMember
    let state: VRRoomState

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showGift = false
    /// 自己看自己的名片时，「编辑名片」直接在这个弹层里打开编辑面板
    @State private var showEdit = false
    @State private var mode: VRCardMode = .compact

    private var user: VRUser { member.user }
    private var isMe: Bool { member.clientId == app.clientId }
    private var isHost: Bool { state.isOwner(member) }
    /// 送给谁：别人的名片 → 预选这个人；自己的名片 → 不预选（默认"全房间"，
    /// 因为"给自己送礼"没有意义，用户点进来通常是想送房里其他人）
    private var giftPreset: String? { isMe ? nil : member.clientId }

    /// 在房时长（分钟）。`joinedAt` 是服务端毫秒时间戳；
    /// 0 表示这条成员记录是本地临时拼出来的（比如从公屏点自己），此时不显示这一项。
    private var stayMinutes: Int? {
        guard member.joinedAt > 0 else { return nil }
        let ms = Date().timeIntervalSince1970 * 1000 - member.joinedAt
        return max(0, Int(ms / 60000))
    }

    /// 封面高度 / 白色信息面板压住封面的高度
    /// （两个数字连同下面面板的内边距，一起控制在 378pt 的固定高度内，见 VRCardDetentModifier）
    private static let bannerHeight: CGFloat = 168
    private static let panelOverlap: CGFloat = 22

    var body: some View {
        ZStack(alignment: .top) {
            VRTheme.bg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    banner
                    // 负 padding：让白面板整体上移压住封面底部。
                    // 用负值时面板"绘制"的位置比它在 VStack 里占的槽位高，
                    // 于是既产生了压边效果，又不会在底部多留一块空白。
                    panel.padding(.top, -Self.panelOverlap)
                }
                .padding(.bottom, 26)
            }
            .vrScrollHidden()
        }
        .modifier(VRCardDetentModifier(mode: $mode))
        .sheet(isPresented: $showGift) {
            GiftSheet(state: state, presetTarget: giftPreset).environmentObject(app)
        }
        .sheet(isPresented: $showEdit) {
            ProfileEditSheet().environmentObject(app)
        }
    }

    // MARK: 封面

    private var banner: some View {
        ZStack {
            LinearGradient(colors: VRTheme.background(for: state.effectiveBackground),
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            RadialGradient(colors: [Color.white.opacity(0.6), .clear],
                           center: .init(x: 0.3, y: 0.2), startRadius: 0, endRadius: 230)

            // 大头像：封面主体（和图片里那张人物立绘位置一致）
            VRAvatarFull(user: user, size: 104,
                         isHost: isHost,
                         isMine: isMe,
                         vipLevel: user.vip ? user.vipLevel : 0,
                         showNeutralRing: true)
                .shadow(color: .black.opacity(0.26), radius: 16, y: 8)

            VStack {
                HStack(alignment: .top) {
                    closeButton
                    Spacer()
                    medals
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
        }
        .frame(height: Self.bannerHeight)
        .clipped()
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.black.opacity(0.3)))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// 右上角勋章排（对应图片里名字上方那一排小圆章）
    ///
    /// 房主那枚 `house.fill` 删掉了：房主的皇冠和金环现在由头像框统一画，
    /// 再挂一枚"房子"章就是同一个身份说两遍，也让头像框的视觉没有落点。
    private var medals: some View {
        HStack(spacing: 6) {
            if user.vip {
                medal("crown.fill", [VRTheme.gold, Color(hex: "FF8A3C")])
            }
            if member.seat >= 0 {
                medal("mic.fill", [VRTheme.green, Color(hex: "22A97C")])
            }
            if isMe {
                medal("person.fill", [Color(hex: "C7A6FF"), Color(hex: "8E5BFF")])
            }
        }
    }

    private func medal(_ symbol: String, _ colors: [Color]) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 26, height: 26)
            .background(
                Circle().fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            )
            .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.8))
            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }

    // MARK: 白色信息面板

    private var panel: some View {
        VStack(spacing: 0) {
            identityRow
            actionRow
            if mode == .full { fullProfile }
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var identityRow: some View {
        HStack(spacing: 12) {
            VRAvatarFull(user: user, size: 54,
                         isHost: isHost,
                         isMine: isMe,
                         vipLevel: user.vip ? user.vipLevel : 0,
                         showNeutralRing: true)
                .shadow(color: .black.opacity(0.14), radius: 7, y: 3)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(user.name)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(VRTheme.text)
                        .lineLimit(1)
                    VRGenderIcon(gender: user.gender)
                    if user.vip {
                        // 名字右侧的等级小章（图片里那个数字徽章的位置）
                        Text("VIP\(user.vipLevel)")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(VRTheme.brandGradient))
                    }
                }
                subtitle
            }

            Spacer(minLength: 4)

            if isMe {
                // 自己的名片：编辑入口放在标题行右侧。
                //
                // 原来这里是「主页 ›」，而下面两个大圆按钮右边那个被换成了「编辑我的名片」——
                // 结果看自己的名片时完全没有「送礼物」这个入口，看着就像送礼功能没了。
                // 现在两个大圆按钮固定是「查看完整主页 / 送礼物」，编辑挪到这个小胶囊上。
                Button { showEdit = true } label: {
                    HStack(spacing: 3) {
                        Text("✏️").font(.system(size: 11))
                        Text("编辑")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(VRTheme.brand)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(VRTheme.brand.opacity(0.13)))
                }
                .buttonStyle(.plain)
            } else {
                Button { toggleFull() } label: {
                    HStack(spacing: 3) {
                        if mode == .compact {
                            Text("主页")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Image(systemName: mode == .full ? "chevron.down" : "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(VRTheme.textMute)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
    }

    /// 名字下面那行小字（对应图片里的「IP: 江苏 | 0m」）。
    /// 我们拿不到 IP 归属地，就换成这张名片确实知道的三件事：性别 / 麦位 / 在房时长。
    private var subtitleTokens: [String] {
        var t: [String] = [user.gender.label]
        t.append(member.seat >= 0 ? "\(member.seat + 1) 号麦" : "听众")
        if isHost { t.append("房主") }
        if let m = stayMinutes { t.append("在房 \(m)m") }
        return t
    }

    private var subtitle: some View {
        var out = Text("")
        for (i, token) in subtitleTokens.enumerated() {
            if i > 0 {
                out = out + Text("  |  ").foregroundColor(VRTheme.textMute.opacity(0.6))
            }
            out = out + Text(token)
        }
        return out
            .font(.system(size: 11.5))
            .foregroundColor(VRTheme.textDim)
    }

    /// 两个大圆按钮：左＝查看完整主页，右＝送礼物。
    ///
    /// 这两个**恒定不变**（对齐参考图）：以前右边那个在"看自己"时会变成「编辑我的名片」，
    /// 于是从自己的麦位/头像点进来就再也找不到送礼入口。编辑名片改挂标题行右侧了。
    private var actionRow: some View {
        HStack(spacing: 44) {
            roundAction("查看完整主页", "person.crop.circle.fill",
                        [Color(hex: "6BD5FF"), Color(hex: "3B8CFF")]) {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { mode = .full }
            }

            roundAction("送礼物", "gift.fill",
                        [Color(hex: "FFA6C9"), Color(hex: "FF5C9E")]) {
                showGift = true
            }
        }
        .padding(.top, 18)
    }

    private func roundAction(_ title: String, _ icon: String, _ colors: [Color],
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: colors,
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 64, height: 64)
                        .shadow(color: colors[1].opacity(0.35), radius: 10, y: 5)
                    Image(systemName: icon)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(.white)
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(VRTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(.plain)
    }

    private func toggleFull() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            mode = (mode == .full) ? .compact : .full
        }
    }

    // MARK: 完整主页（compact 时隐藏）

    @ViewBuilder
    private var fullProfile: some View {
        VStack(spacing: 14) {
            Rectangle()
                .fill(Color(hex: "27436B").opacity(0.08))
                .frame(height: 1)
                .padding(.top, 18)

            HStack(spacing: 10) {
                statBox(title: "💰 金币", value: shortNum(user.coins), color: VRTheme.gold)
                statBox(title: "💖 魅力值", value: shortNum(user.charm), color: VRTheme.pink)
                statBox(title: "👑 会员",
                        value: user.vip ? "VIP\(user.vipLevel)" : "普通",
                        color: user.vip ? VRTheme.gold : VRTheme.textDim)
            }
            .padding(.horizontal, 18)

            // VIP 等级与刷礼物挂钩：展示晋升进度（自身已带水平内边距）
            vipProgress

            if !user.bio.isEmpty {
                Text(user.bio)
                    .font(.system(size: 13))
                    .foregroundColor(VRTheme.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            if !isMe {
                Button("✉️ 打个招呼") {
                    app.sendChat("@\(user.name) 你好呀 👋")
                    dismiss()
                }
                .buttonStyle(VRButtonStyle(fullWidth: true))
                .padding(.horizontal, 18)
            }

            Button("收起主页") { toggleFull() }
                .buttonStyle(VRButtonStyle(kind: .plain, fullWidth: true))
                .padding(.horizontal, 18)
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
        let charm = user.charm
        let cur = VIPCharmStairs.level(for: charm)
        let next = VIPCharmStairs.nextThreshold(for: charm)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text("👑 VIP 等级")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(VRTheme.textDim)
                Spacer()
                Text(user.vip ? "VIP\(user.vipLevel)" : "未激活")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(user.vip ? VRTheme.gold : VRTheme.textMute)
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
        .padding(.horizontal, 18)
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
