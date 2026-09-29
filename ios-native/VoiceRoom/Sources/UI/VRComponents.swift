import SwiftUI

// MARK: - 头像

struct VRAvatar: View {
    let user: VRUser?
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            if let user, user.hasCustomAvatar, let url = avatarURL(user.avatar) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    default:
                        fallback(user)
                    }
                }
            } else {
                fallback(user)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    @ViewBuilder
    private func fallback(_ user: VRUser?) -> some View {
        let name = user?.name ?? "?"
        let seed = user?.id ?? name
        ZStack {
            LinearGradient(
                colors: [VRTheme.avatarColor(seed: seed),
                         VRTheme.avatarColor(seed: seed + "2")],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Text(String(name.trimmingCharacters(in: .whitespaces).first ?? "?").uppercased())
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundColor(.white)
        }
    }

    private func avatarURL(_ s: String) -> URL? {
        if s.hasPrefix("data:image") {
            // dataURL 交给 AsyncImage 无法直接处理，需转为 UIImage
            return nil
        }
        return URL(string: s)
    }
}

/// 完整头像视图：支持 dataURL、服务端 URL（/avatar/xxx）、GIF 动图与透明 PNG
///
/// 头像框（房主 / VIP / 说话 / 我自己）也画在这里，而不是让每个调用点自己叠 overlay。
/// 原因：调用点自己叠的话，麦位上会出现「白边 + 绿圈 + 金圈」三层环同时压在同一张头像上，
/// 而且每个地方各写一套、颜色还会走样。统一在组件里按优先级**只画一圈**，各处传参即可。
///
/// 新增参数都带默认值，老调用点不传就是原样，不会因为这次改动而变形。
struct VRAvatarFull: View {
    let user: VRUser?
    var size: CGFloat = 40

    // MARK: 头像框参数

    /// 房主 → 金色环 + 顶部皇冠
    var isHost: Bool = false
    /// 我自己 → 品牌蓝环
    var isMine: Bool = false
    /// 正在说话 → 绿色环
    var speaking: Bool = false
    /// VIP 等级（0 表示非 VIP）→ 按等级分色环 + 右下角等级小徽章
    var vipLevel: Int = 0
    /// 以上都不适用时，要不要画一圈默认的白色描边（麦位在背景图上需要它来分离边缘；列表里不需要）
    var showNeutralRing: Bool = false

    @State private var image: UIImage?
    /// 当前这次加载对应的头像 URL；回调到达时校验，丢弃过期结果
    @State private var loadingKey: String?

    var body: some View {
        Group {
            if let image {
                // GIF 动图用 UIImageView 承载才能播放
                if image.images != nil {
                    GIFImageView(image: image, contentMode: .scaleAspectFill)
                        .frame(width: size, height: size)
                } else {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            } else {
                VRAvatar(user: user, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { ringView }
        .overlay(alignment: .bottomTrailing) { vipLevelBadge }
        .overlay(alignment: .top) { crownBadge }
        .onAppear(perform: loadIfNeeded)
        .onChange(of: user?.avatar) { _ in
            image = nil
            loadingKey = nil
            loadIfNeeded()
        }
        // 换人了（列表复用、麦位换人）也要重载：
        // 只看 avatar 字符串不够 —— 两个人可能都还是"没设头像"的空串，
        // 那样视图被复用时会继续显示上一个人的图。
        .onChange(of: user?.id) { _ in
            image = nil
            loadingKey = nil
            loadIfNeeded()
        }
    }

    // MARK: - 头像框

    /// 环的配色。优先级：正在说话 > 房主 > VIP > 我自己 > 默认白边。
    /// 只取一个，不叠加 —— 叠起来一圈套一圈，小头像上会糊成一坨。
    private var ringColors: [Color]? {
        if speaking { return [VRTheme.green, Color(hex: "22A97C")] }
        if isHost { return [Color(hex: "FFE08A"), Color(hex: "FF9F1C")] }
        if vipLevel > 0 { return Self.vipRingColors(vipLevel) }
        if isMine { return [VRTheme.brand, Color(hex: "6FC4FF")] }
        if showNeutralRing { return [Color.white.opacity(0.62), Color.white.opacity(0.42)] }
        return nil
    }

    /// VIP 分档配色，和服务端的 VIP 阶梯对齐：
    /// 1-3 银蓝 / 4-6 紫 / 7-9 金 / 10+ 三色（粉金蓝）
    private static func vipRingColors(_ level: Int) -> [Color] {
        switch level {
        case ..<4:  return [Color(hex: "CFE6FF"), Color(hex: "6FA8FF")]
        case 4...6: return [Color(hex: "D9B3FF"), Color(hex: "8E5BFF")]
        case 7...9: return [Color(hex: "FFE08A"), Color(hex: "FF9F1C")]
        default:    return [Color(hex: "FF7FAE"), Color(hex: "FFD86B"), Color(hex: "7ED0FF")]
        }
    }

    @ViewBuilder
    private var ringView: some View {
        if let colors = ringColors {
            Circle()
                .strokeBorder(
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: max(1.6, size * 0.045)
                )
                // VIP / 房主的环加一点发光，看起来"bling bling"
                .shadow(color: (colors.last ?? .clear).opacity(vipLevel > 0 || isHost ? 0.55 : 0),
                        radius: 4)
        }
    }

    /// VIP 等级徽章的直径（太小的头像上不画徽章，否则糊成一团）
    private var badgeDiameter: CGFloat { max(15, size * 0.36) }

    /// 右下角 VIP 等级小徽章
    @ViewBuilder
    private var vipLevelBadge: some View {
        if vipLevel > 0 && size >= 38 && !speaking {
            Text("\(vipLevel)")
                .font(.system(size: badgeDiameter * 0.62, weight: .heavy))
                .foregroundColor(.white)
                .frame(width: badgeDiameter, height: badgeDiameter)
                .background(
                    Circle().fill(LinearGradient(colors: Self.vipRingColors(vipLevel),
                                                 startPoint: .top, endPoint: .bottom))
                )
                .overlay(Circle().strokeBorder(.white, lineWidth: 1.4))
                .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                .offset(x: 1, y: 1)
        }
    }

    /// 房主皇冠（压在头像顶部）
    @ViewBuilder
    private var crownBadge: some View {
        if isHost && size >= 38 {
            Text("👑")
                .font(.system(size: max(11, size * 0.26)))
                .offset(y: -max(6, size * 0.14))
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        }
    }

    private func loadIfNeeded() {
        guard let s = user?.avatar, !s.isEmpty else {
            image = nil
            return
        }

        // 1) dataURL（历史上传的老数据 / 本地预览）
        if s.hasPrefix("data:image"), let range = s.range(of: "base64,") {
            let b64 = String(s[range.upperBound...])
            if let data = Data(base64Encoded: b64) { image = MediaCache.decode(data, profile: .avatar) }
            return
        }

        // 2) 服务端文件地址（/avatar/xxx.png）；走 MediaCache：URL 不变就不重复下载
        guard let url = absoluteAvatarURL(s) else { return }
        // 记下这次加载的目标，回调里用来丢弃过期结果
        loadingKey = url.absoluteString
        if let hit = MediaCache.shared.cachedImage(for: url, profile: .avatar) {
            image = hit
            return
        }
        MediaCache.shared.image(for: url, profile: .avatar) { [self] img in
            // 头像换了 / 视图被复用给了别人时，迟到的旧图不能覆盖新图
            guard loadingKey == url.absoluteString else { return }
            image = img
        }
    }

    private func absoluteAvatarURL(_ s: String) -> URL? {
        if s.hasPrefix("http") { return URL(string: s) }
        guard let base = VRConfig.baseURL else { return nil }
        return URL(string: s, relativeTo: base)
    }
}

// MARK: - 按钮样式

struct VRButtonStyle: ButtonStyle {
    enum Kind {
        case primary, pink, gold, plain
    }
    var kind: Kind = .plain
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(foreground)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(minHeight: 46)
            .padding(.horizontal, kind == .plain ? 18 : 20)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(VRTheme.border, lineWidth: kind == .plain ? 1 : 0)
            )
            .shadow(color: shadowColor, radius: kind == .primary || kind == .pink || kind == .gold ? 12 : 0, y: 4)
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }

    private var foreground: Color {
        switch kind {
        case .gold: return Color(hex: "3A2500")
        default: return VRTheme.text
        }
    }

    @ViewBuilder
    private var background: some View {
        switch kind {
        case .primary: VRTheme.brandGradient
        case .pink:    VRTheme.pinkGradient
        case .gold:    VRTheme.goldGradient
        case .plain:   Color.white.opacity(0.85)
        }
    }

    private var shadowColor: Color {
        switch kind {
        case .primary: return VRTheme.brand.opacity(0.42)
        case .pink:    return VRTheme.pink.opacity(0.36)
        case .gold:    return VRTheme.gold.opacity(0.34)
        case .plain:   return .clear
        }
    }
}

// MARK: - 小图标按钮

struct VRIconButton: View {
    let icon: String
    var active: Bool = false
    var danger: Bool = false
    var size: CGFloat = 40
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(icon)
                .font(.system(size: size * 0.45))
                .frame(width: size, height: size)
                .background(bg)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(strokeColor, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var bg: some View {
        Group {
            if danger { VRTheme.red.opacity(0.18) }
            else if active { VRTheme.brandGradient }
            else { Color.white.opacity(0.9) }
        }
    }

    private var strokeColor: Color {
        if danger { VRTheme.red.opacity(0.45) }
        else if active { .clear }
        else { VRTheme.border }
    }
}

// MARK: - 玻璃卡片

struct VRCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: VRTheme.radius, style: .continuous)
                    .fill(VRTheme.panel)
                    .background(
                        RoundedRectangle(cornerRadius: VRTheme.radius, style: .continuous)
                            .fill(.ultraThinMaterial.opacity(0.5))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: VRTheme.radius, style: .continuous)
                    .strokeBorder(VRTheme.border, lineWidth: 1)
            )
    }
}

// MARK: - 输入框

struct VRTextField: View {
    let placeholder: String
    @Binding var text: String
    var maxLength: Int = 40
    var keyboard: UIKeyboardType = .default
    var secure = false

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .keyboardType(keyboard)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(.system(size: 15))
        .foregroundColor(VRTheme.text)
        .padding(.horizontal, 15)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(VRTheme.border, lineWidth: 1)
        )
        .onChange(of: text) { newValue in
            if newValue.count > maxLength {
                text = String(newValue.prefix(maxLength))
            }
        }
    }
}

// MARK: - 徽章

struct VRBadge: View {
    enum Kind { case vip, host, normal, green }
    var kind: Kind = .normal
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy))
            .foregroundColor(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var fg: Color {
        switch kind {
        case .vip: return Color(hex: "4A2C00")
        case .host: return .white
        case .normal: return VRTheme.textDim
        case .green: return VRTheme.green
        }
    }

    @ViewBuilder
    private var bg: some View {
        switch kind {
        case .vip:    VRTheme.goldGradient
        case .host:   LinearGradient(colors: [Color(hex: "6BD5FF"), Color(hex: "3B8CFF")],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
        case .normal: Color(hex: "27436B").opacity(0.08)
        case .green:  VRTheme.green.opacity(0.16)
        }
    }
}

// MARK: - 性别图标

struct VRGenderIcon: View {
    let gender: Gender
    var body: some View {
        Text(gender.symbol)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(color)
    }
    private var color: Color {
        switch gender {
        case .male: return VRTheme.brand2
        case .female: return VRTheme.pink
        case .secret: return VRTheme.textMute
        }
    }
}

// MARK: - 数字简写

func shortNum(_ n: Int) -> String {
    let v = Double(n)
    if v >= 100_000_000 { return String(format: "%.1f亿", v / 100_000_000).replacingOccurrences(of: ".0", with: "") }
    if v >= 10_000 { return String(format: "%.1f万", v / 10_000).replacingOccurrences(of: ".0", with: "") }
    return String(n)
}

// MARK: - Toast

struct VRToastView: View {
    let message: AppState.ToastMessage

    var body: some View {
        Text(message.text)
            .font(.system(size: 13.5, weight: .medium))
            .foregroundColor(fgColor)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.97))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1.5)
            )
            .shadow(color: VRTheme.text.opacity(0.16), radius: 14, y: 5)
            .padding(.horizontal, 40)
    }

    private var fgColor: Color {
        switch message.kind {
        case .error: return VRTheme.red
        case .success: return VRTheme.green
        case .info: return VRTheme.text
        }
    }

    private var borderColor: Color {
        switch message.kind {
        case .error: return VRTheme.red.opacity(0.55)
        case .success: return VRTheme.green.opacity(0.5)
        case .info: return VRTheme.border
        }
    }
}

// MARK: - 底部弹层容器

struct VRSheet<Content: View>: View {
    let title: String
    var onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            VStack(spacing: 0) {
                // 把手
                Capsule()
                    .fill(Color(hex: "27436B").opacity(0.22))
                    .frame(width: 38, height: 4)
                    .padding(.top, 8)
                    .padding(.bottom, 14)

                // 标题
                HStack {
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(VRTheme.text)
                    Spacer()
                    Button(action: onClose) {
                        Text("✕")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(VRTheme.textMute)
                            .frame(width: 28, height: 28)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

                ScrollView {
                    content
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                }
                .vrScrollHidden()
            }
            .frame(maxHeight: UIScreen.main.bounds.height * 0.84)
            .background(
                Color.white
                    .clipShape(RoundedCorner(radius: 22, corners: [.topLeft, .topRight]))
                    .ignoresSafeArea(edges: .bottom)
            )
            .overlay(
                RoundedCorner(radius: 22, corners: [.topLeft, .topRight])
                    .stroke(VRTheme.border, lineWidth: 1)
                    .ignoresSafeArea(edges: .bottom)
            )
        }
    }
}

/// 可指定圆角的形状
struct RoundedCorner: Shape {
    var radius: CGFloat = 0
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}

// MARK: - 分段选择器

struct VRSegmentedControl<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { opt in
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { selection = opt.value }
                } label: {
                    Text(opt.label)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(selection == opt.value ? .white : VRTheme.textDim)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            Group {
                                if selection == opt.value {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(VRTheme.brandGradient)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
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


// MARK: - VIP 房间的金色闪光氛围

/// 房主是 VIP 时铺在房间背景上的一层氛围：暖金色流光 + 几颗缓慢闪烁的星点。
///
/// 性能上刻意做成「固定几个视图 + 持续动画」：
/// 星点数量固定（7 个），位置用下标算伪随机（不放随机数，重绘时不会跳位），
/// 闪烁全部交给 Core Animation 的 repeatForever 驱动 —— 不需要每帧重算 SwiftUI 的 body，
/// 所以开着它也不会持续占 CPU。`.allowsHitTesting(false)` 保证它不吃任何点击。
struct GoldShimmerLayer: View {

    /// 星点数量
    var stars: Int = 7
    /// 叠加在房间背景上的强度（0~1）
    var intensity: Double = 1

    @State private var on = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(hex: "FFD86B").opacity((on ? 0.17 : 0.07) * intensity),
                        .clear,
                        Color(hex: "FFA53C").opacity((on ? 0.14 : 0.05) * intensity)
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )

                ForEach(0..<stars, id: \.self) { i in
                    starView(i, in: geo.size)
                }
            }
            .onAppear { on = true }
        }
        .allowsHitTesting(false)
    }

    private func starView(_ i: Int, in size: CGSize) -> some View {
        let p = Self.position(i, in: size)
        return Circle()
            .fill(Color(hex: "FFF6CF"))
            .frame(width: p.r, height: p.r)
            .shadow(color: Color(hex: "FFD86B").opacity(0.95), radius: 6)
            .position(x: p.x, y: p.y)
            .opacity((on ? 0.95 : 0.12) * intensity)
            .scaleEffect(on ? 1.28 : 0.62)
            .animation(
                .easeInOut(duration: 1.5 + Double(i % 3) * 0.55)
                    .repeatForever(autoreverses: true)
                    .delay(Double(i) * 0.26),
                value: on
            )
    }

    /// 固定分布（下标越界自动回绕），避免引入随机数导致每次重绘星点乱跳
    private static func position(_ i: Int, in size: CGSize) -> (x: CGFloat, y: CGFloat, r: CGFloat) {
        let fx: [CGFloat] = [0.14, 0.83, 0.33, 0.69, 0.21, 0.91, 0.52]
        let fy: [CGFloat] = [0.11, 0.19, 0.35, 0.47, 0.65, 0.76, 0.88]
        let fr: [CGFloat] = [3.6, 2.6, 4.2, 3.0, 2.4, 3.6, 2.8]
        let k = i % fx.count
        return (size.width * fx[k], size.height * fy[k], fr[k])
    }
}

// MARK: - iOS 15/16 兼容助手
//
// 部署目标是 iOS 15，但部分代码用了 iOS 16 的 API。
// 这里统一封装：16+ 走新 API，15 静默降级为可用效果。

extension View {
    /// ScrollView 隐藏滚动条（iOS 15：保持默认，仅外观差异）
    @ViewBuilder
    func vrScrollHidden() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollIndicators(.hidden)
        } else {
            self
        }
    }

    /// 滚动即收起键盘（iOS 15：无等效 API，键盘由工具栏/点击收起）
    @ViewBuilder
    func vrScrollDismissKeyboard() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }

    /// 半屏/全屏 sheet + 拖动条（iOS 15：普通全屏 sheet）
    @ViewBuilder
    func vrSheet(medium: Bool = false, large: Bool = true) -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents(Self.vrDetents(medium: medium, large: large))
                .presentationDragIndicator(.visible)
        } else {
            self
        }
    }

    @available(iOS 16.0, *)
    private static func vrDetents(medium: Bool, large: Bool) -> Set<PresentationDetent> {
        var s = Set<PresentationDetent>()
        if medium { s.insert(.medium) }
        if large { s.insert(.large) }
        return s
    }

    /// NavigationStack 的 iOS 15 替代（NavigationView + stack 风格）
    @ViewBuilder
    func vrNavigationStack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 16.0, *) {
            NavigationStack(root: content)
        } else {
            NavigationView(content: content).navigationViewStyle(.stack)
        }
    }
}

// MARK: - 相册选图（iOS 15 可用；PhotosPicker 需要 iOS 16）

/// 相册选图：同时回传 UIImage 与**原始文件数据**（用于保留 GIF 动画 / PNG 透明）
struct VRPhotoPicker: UIViewControllerRepresentable {
    var onPicked: (UIImage, Data?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .photoLibrary
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: VRPhotoPicker
        init(_ parent: VRPhotoPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let img = info[.originalImage] as? UIImage
            // 原始文件数据：GIF / PNG 都靠它保留动画与透明
            var raw: Data? = nil
            if let url = info[.imageURL] as? URL {
                raw = try? Data(contentsOf: url)
            }
            if raw == nil, let i = img { raw = i.pngData() }
            if let img { parent.onPicked(img, raw) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
