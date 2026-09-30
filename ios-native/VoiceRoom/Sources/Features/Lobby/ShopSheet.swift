import SwiftUI

/// 头像框商城 / 背包。
///
/// 两个入口共用这一个页面（首页「商城」= 买，设置「背包」= 换）：
/// 数据本来就完全一样（同一份商品清单 + 同一份已拥有列表），
/// 拆成两个页面只会让「买完想换一个」变成两个地方来回翻。
///
/// 商品清单由服务端下发（`config.avatarFrames`），客户端只负责通用渲染：
/// 渐变环 + 角标 + 可选外发光。以后加新头像框不用改这里、也不用发版。
struct ShopSheet: View {

    enum Mode: String, CaseIterable, Identifiable {
        case shop, backpack
        var id: String { rawValue }
        var title: String { self == .shop ? "头像框商城" : "我的背包" }
        var label: String { self == .shop ? "商城" : "背包" }
    }

    /// 从哪个入口进来的（只决定默认选中哪一段）
    var initialMode: Mode = .shop

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var mode: Mode = .shop

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        ZStack {
            VRTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 14) {
                        walletCard

                        if app.shopFrames.isEmpty {
                            loadingHint
                        } else {
                            grid(mode == .shop ? shopList : backpackList)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
        }
        .vrSheet()
        .onAppear {
            mode = initialMode
            app.requestShop()
        }
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(mode.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(VRTheme.text)

                Spacer()

                if app.frameBusy {
                    ProgressView().scaleEffect(0.8)
                }

                Button { dismiss() } label: {
                    Text("✕")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(VRTheme.textDim)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color(hex: "27436B").opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var walletCard: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("我的金币")
                    .font(.system(size: 11.5))
                    .foregroundColor(VRTheme.textDim)
                Text("💰 \(shortNum(app.me?.coins ?? 0))")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundColor(VRTheme.gold)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("已拥有")
                    .font(.system(size: 11.5))
                    .foregroundColor(VRTheme.textDim)
                Text("\(backpackList.count) 个")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundColor(VRTheme.brand)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color(hex: "27436B").opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(VRTheme.border, lineWidth: 1)
        )
    }

    private var loadingHint: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.85)
            Text("正在读取头像框…")
                .font(.system(size: 12.5))
                .foregroundColor(VRTheme.textDim)
        }
        .padding(.top, 40)
    }

    // MARK: - 列表

    /// 商城：全部商品，便宜的排前面
    private var shopList: [VRAvatarFrame] {
        app.shopFrames.sorted { $0.price < $1.price }
    }

    /// 背包：默认框 + 我买过的
    private var backpackList: [VRAvatarFrame] {
        let owned = Set(app.ownedFrames)
        return app.shopFrames
            .filter { $0.price == 0 || owned.contains($0.id) }
            .sorted { $0.price < $1.price }
    }

    private func grid(_ list: [VRAvatarFrame]) -> some View {
        LazyVGrid(columns: columns, spacing: 13) {
            ForEach(list) { f in
                tile(f)
            }
        }
    }

    // MARK: - 单个头像框

    private func tile(_ f: VRAvatarFrame) -> some View {
        let owned = app.ownsFrame(f.id)
        let wearing = (app.me?.frame ?? "") == f.id

        return VStack(spacing: 7) {
            // 预览：拿我自己的头像套上这个框，所见即所得
            VRAvatarFull(user: previewUser(f.id), size: 54,
                         isMine: true,
                         vipLevel: app.me?.vip == true ? (app.me?.vipLevel ?? 1) : 0,
                         showNeutralRing: true)
                .frame(height: 62)

            Text(f.name)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(VRTheme.text)
                .lineLimit(1)

            tierBadge(f)

            actionButton(f, owned: owned, wearing: wearing)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 7)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(wearing ? VRTheme.green.opacity(0.10) : Color.white.opacity(0.66))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(wearing ? VRTheme.green.opacity(0.7) : VRTheme.border, lineWidth: 1.2)
        )
    }

    /// 预览用：把我自己的资料复制一份、换上头像框 id
    private func previewUser(_ frameId: String?) -> VRUser? {
        guard var u = app.me else { return nil }
        u.frame = frameId
        return u
    }

    @ViewBuilder
    private func tierBadge(_ f: VRAvatarFrame) -> some View {
        if let t = f.tier, t != "normal" {
            Text(tierLabel(t))
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(tierColor(t)))
        }
    }

    private func tierLabel(_ t: String) -> String {
        switch t {
        case "rare":   return "稀有"
        case "epic":   return "史诗"
        case "legend": return "传说"
        default:       return t
        }
    }

    private func tierColor(_ t: String) -> Color {
        switch t {
        case "rare":   return VRTheme.brand
        case "epic":   return Color(hex: "8E5BFF")
        case "legend": return VRTheme.gold
        default:       return VRTheme.textDim
        }
    }

    @ViewBuilder
    private func actionButton(_ f: VRAvatarFrame, owned: Bool, wearing: Bool) -> some View {
        if wearing {
            Button { app.wearFrame(nil) } label: {
                pill("脱下", fill: VRTheme.green)
            }
            .buttonStyle(.plain)
        } else if owned {
            Button { app.wearFrame(f.id) } label: {
                pill("戴上", fill: VRTheme.brand)
            }
            .buttonStyle(.plain)
        } else {
            Button { app.buyFrame(f.id) } label: {
                pill("💰 \(shortNum(f.price))", fill: VRTheme.gold)
            }
            .buttonStyle(.plain)
            .disabled(app.frameBusy)
        }
    }

    private func pill(_ text: String, fill: Color) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .bold))
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .frame(height: 29)
            .background(Capsule().fill(fill))
    }
}
