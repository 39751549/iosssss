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
/// 头像框样式表（服务端 `config.avatarFrames` 下发）。
///
/// 为什么做成全局单例：头像渲染发生在 `VRAvatarFull` 里，而它只拿得到一个 `frame` **id** ——
/// 背包/配色不进每个成员的快照（房间里 9 个人都驮一份数组太浪费带宽）。
/// 所以样式单独存一份，商城拉到清单后写进来，所有头像跟着重绘一次。
///
/// 加新头像框只需要在服务端数组里加一条，客户端不用改代码、不用发版。
final class VRFrameCatalog: ObservableObject {

    static let shared = VRFrameCatalog()

    @Published private(set) var frames: [VRAvatarFrame] = []

    func setFrames(_ list: [VRAvatarFrame]) {
        // 内容没变就别发通知：否则每次打开商城都会把所有头像重绘一遍
        guard list != frames else { return }
        frames = list
    }

    /// 按 id 取头像框；id 为空（没戴）时返回 nil
    func frame(_ id: String?) -> VRAvatarFrame? {
        guard let id, !id.isEmpty else { return nil }
        return frames.first { $0.id == id }
    }

    /// 默认框（price = 0）
    var defaultFrame: VRAvatarFrame? { frames.first { $0.price == 0 } }
}

struct VRAvatarFull: View {
    let user: VRUser?
    var size: CGFloat = 40

    // MARK: 头像框参数

    /// 正在说话 → 绿色环（唯一一个"当下状态"环）
    var speaking: Bool = false
    /// 以上都不适用时，要不要画一圈默认的白色描边（麦位在背景图上需要它来分离边缘；列表里不需要）
    var showNeutralRing: Bool = false

    @State private var image: UIImage?
    /// 当前这次加载对应的头像 URL；回调到达时校验，丢弃过期结果
    @State private var loadingKey: String?
    /// 图片头像框的素材图（服务端下发的 264x264 中心透明 PNG）
    @State private var frameImage: UIImage?
    /// 头像框素材这次加载的目标 URL，同样用于丢弃过期结果
    @State private var frameLoadingKey: String?

    /// 头像框样式表（见 VRFrameCatalog 的说明）
    @ObservedObject private var catalog = VRFrameCatalog.shared

    /// 当前头像框的素材地址；换框 / 换人时靠它触发重新加载
    private var frameImageKey: String { frame?.img ?? "" }

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
        // 头像框外发光（只有标了 glow 的框才有；其余返回 .clear 等于没画）
        .shadow(color: frameGlowColor, radius: frameGlowRadius)
        .overlay { ringView }
        // 图片头像框：整张素材叠在头像之上。素材中心透明，贴边不遮脸，
        // 必须画在 ringView 之后（图片框不再画渐变环，见 ringColors 的注释）
        .overlay { frameArtView }
        // 头像上**什么都不压**：皇冠、等级章、框角标、静音标全部撤掉。
        // 这类 App 最好看的就是头像本身，任何角标都是在给脸打码；
        // 身份 / 状态一律交给头像外的元素表达（名字颜色、「房」标、名字行的静音标）。
        .onAppear {
            loadIfNeeded()
            loadFrameArtIfNeeded()
        }
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
        .onChange(of: user?.frame) { _ in loadFrameArtIfNeeded() }
        // 商城清单晚于头像到达（先进房间后拉商城）→ 框素材到了要补加载
        .onChange(of: frameImageKey) { _ in loadFrameArtIfNeeded() }
    }

    // MARK: - 头像框

    /// 这个人当前戴的头像框（没戴 / 还没拉到样式表 → nil）
    private var frame: VRAvatarFrame? { catalog.frame(user?.frame) }

    private var frameGlowColor: Color {
        guard let f = frame, f.glow == true, let c = f.colors.first else { return .clear }
        return Color(hex: c).opacity(0.55)
    }

    private var frameGlowRadius: CGFloat {
        guard let f = frame, f.glow == true else { return 0 }
        return max(5, size * 0.16)
    }


    /// 环的配色。
    ///
    /// **只有两种环**：正在说话（绿）、已穿戴的头像框（买来的）。其余返回白描边或 nil。
    ///
    /// 这里原来是"说话 > 头像框 > 房主金环 > VIP 分色环 > 我自己蓝环 > 白边"，
    /// 问题是后面那三种都是**身份**环：跟人在不在麦上、有没有说话毫无关系，
    /// 于是哪怕静音、哪怕只是挂在房间里，头像也一直顶着一圈彩色光 ——
    /// 用户的原话是"我没打开麦克风，为什么周围显示光圈"。
    ///
    /// 现在的分工：**环表达"此刻在做什么"（说话），名字表达"我是谁"**
    /// （VIP 等级 → 名字颜色 / 流光；房主 → 名字后面的「房」字标）。
    /// 两者不再互相重复，也就不会到处冒光圈了。
    private var ringColors: [Color]? {
        if speaking { return [VRTheme.green, Color(hex: "22A97C")] }
        // 花钱买的头像框：买了看不见等于没买，这个留住
        if let f = frame {
            // 图片素材框不画渐变环 —— 框本身就是一张图，环会被整圈盖住，
            // 两层叠在一起边缘发糊。图片加载失败时也不补环，宁可素一点
            if (f.img ?? "").isEmpty {
                let cs = f.colors.compactMap { Color(hex: $0) }
                if cs.count >= 2 { return cs }
                if let only = cs.first { return [only, only] }
            }
        }
        if showNeutralRing { return [Color.white.opacity(0.62), Color.white.opacity(0.42)] }
        return nil
    }

    /// 图片头像框：服务端下发的整张素材（264x264、中心透明），
    /// 按 1:1 叠在头像上，贴边环绕不遮脸。
    @ViewBuilder
    private var frameArtView: some View {
        if let ui = frameImage {
            Image(uiImage: ui)
                .resizable()
                .frame(width: size, height: size)
                // 说话状态在图片框上的表达：环会被框图盖住，改用一圈绿光
                .shadow(color: speaking ? VRTheme.green.opacity(0.6) : .clear,
                        radius: speaking ? max(4, size * 0.12) : 0)
        }
    }

    private func loadFrameArtIfNeeded() {
        guard let path = frame?.img, !path.isEmpty else {
            frameImage = nil
            frameLoadingKey = nil
            return
        }
        guard let url = absoluteAvatarURL(path) else { return }
        frameLoadingKey = url.absoluteString
        if let hit = MediaCache.shared.cachedImage(for: url, profile: .avatar) {
            frameImage = hit
            return
        }
        MediaCache.shared.image(for: url, profile: .avatar) { [self] img in
            guard frameLoadingKey == url.absoluteString else { return }
            frameImage = img
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
                // 只有说话绿灯那圈发光（有呼吸感）；白描边保持素净，
                // 它只是为了让头像在背景图上不糊掉，不是装饰
                .shadow(color: (colors.last ?? .clear).opacity(speaking ? 0.55 : 0), radius: 4)
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

// MARK: - VIP 名字特权

/// VIP 等级对应的「名字特权」档位。
///
/// 设计原则：**等级数字只出现在名片里**。麦位、公屏、成员列表、飘屏都不再贴 `VIP11` 这种
/// 数字标签 —— 满屏数字既廉价又吵。身份改用名字本身的颜色 / 流光来表达：
/// 一眼能看出"这人是大佬"，但不会每行都在报数字。
///
/// 档位（和服务端的 VIP 阶梯对齐，也和头像环分色保持一致）：
/// | 等级 | 名字 |
/// |---|---|
/// | 1-4  | 银蓝，静态 |
/// | 5-7  | 金色，轻微外发光 |
/// | 8-10 | 紫色，白光扫过 |
/// | 11+  | 三色流动，流光更快 + 强外发光 |
enum VRNameTier: Equatable {
    case plain
    case silver
    case gold
    case violet
    case aurora

    init(vip: Bool, level: Int) {
        guard vip, level > 0 else { self = .plain; return }
        switch level {
        case ..<5:   self = .silver
        case 5..<8:  self = .gold
        case 8..<11: self = .violet
        default:     self = .aurora
        }
    }

    /// 名字的渐变色。
    ///
    /// 分浅底 / 深底两套：同一组颜色不可能在白底面板和深色房间背景上都好看 ——
    /// 浅蓝银放在白色气泡上几乎看不见，深紫放在暗背景里又会糊成一团。
    func colors(onLight: Bool) -> [Color] {
        switch self {
        case .plain:
            return []
        case .silver:
            return onLight
                ? [Color(hex: "7FA9DD"), Color(hex: "4A7EC7")]
                : [Color(hex: "EFF7FF"), Color(hex: "A8CCFF")]
        case .gold:
            return onLight
                ? [Color(hex: "E8A400"), Color(hex: "C97A00")]
                : [Color(hex: "FFF0B8"), Color(hex: "FFB53C"), Color(hex: "FF8A00")]
        case .violet:
            return onLight
                ? [Color(hex: "9B4DE8"), Color(hex: "6D28D9")]
                : [Color(hex: "E9D2FF"), Color(hex: "B368FF"), Color(hex: "8B3FE8")]
        case .aurora:
            return onLight
                ? [Color(hex: "FF3D7F"), Color(hex: "E09400"), Color(hex: "1E9BE8"), Color(hex: "8B5CF6")]
                : [Color(hex: "FF7FAE"), Color(hex: "FFD86B"), Color(hex: "7ED0FF"), Color(hex: "C79BFF")]
        }
    }

    /// 外发光（颜色 + 半径）；nil 表示不发光
    func glow(onLight: Bool) -> (Color, CGFloat)? {
        switch self {
        case .plain, .silver:
            return nil
        case .gold:
            return (Color(hex: "FFB53C").opacity(onLight ? 0.38 : 0.62), onLight ? 3 : 4)
        case .violet:
            return (Color(hex: "A855F7").opacity(onLight ? 0.5 : 0.8), onLight ? 4 : 6)
        case .aurora:
            return (Color(hex: "FF7FAE").opacity(onLight ? 0.6 : 0.9), onLight ? 5 : 9)
        }
    }

    /// 白光扫过字形的周期；nil = 不扫。
    ///
    /// 只有 8 级以上才扫 —— 公屏一热闹几十条消息同时在闪，那就不是"炫酷"是"眼瞎"了。
    var shinePeriod: Double? {
        switch self {
        case .plain, .silver, .gold: return nil
        case .violet: return 2.6
        case .aurora: return 1.7
        }
    }
}

/// 带 VIP 特权的名字。
///
/// 非 VIP 走 `baseColor`（麦位上是白色、公屏上是品牌粉），保持原有观感不变。
/// VIP 则用渐变填字 + 外发光 +（8 级以上）一道白光横着扫过字形。
struct VRNameText: View {
    let name: String
    var vip: Bool = false
    var vipLevel: Int = 0
    /// 这个人是不是房主 → 名字后面跟一个红「房」字标。
    ///
    /// 房主原来靠头像顶上的皇冠区分，三个问题：小头像上皇冠糊成一团、
    /// 只看得见头像看不见名字的地方就认不出、房主换到 1-8 号麦后更是彻底失踪。
    /// 名字后面的字标在麦位 / 公屏 / 成员列表 / 名片四处都跟着人走，
    /// 而且"谁在说话"和"谁是房主"这两件事从此各用各的表达方式，不会打架。
    var isHost: Bool = false
    var size: CGFloat = 11.5
    var weight: Font.Weight = .semibold
    /// 非 VIP 的底色
    var baseColor: Color = .white
    /// 名字所在的底是浅色（白色面板）还是深色（房间背景 / 飘屏）——决定用哪套配色
    var onLight: Bool = false
    var lineLimit: Int? = 1

    /// 白光的水平进度：-0.6 时整条光在文字左侧外面，1.2 时在右侧外面
    @State private var shine: CGFloat = -0.6

    private var tier: VRNameTier { VRNameTier(vip: vip, level: vipLevel) }
    private var font: Font { .system(size: size, weight: weight) }

    var body: some View {
        HStack(spacing: max(3, size * 0.26)) {
            nameLabel
            if isHost { hostTag }
        }
        .lineLimit(lineLimit)
        .minimumScaleFactor(0.75)
        .onAppear(perform: startShine)
    }

    @ViewBuilder
    private var nameLabel: some View {
        Group {
            if tier == .plain {
                Text(name)
                    .font(font)
                    .foregroundColor(baseColor)
            } else {
                Text(name)
                    .font(font)
                    .foregroundStyle(
                        LinearGradient(colors: tier.colors(onLight: onLight),
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .overlay { shineLayer }
                    .shadow(color: glowColor, radius: glowRadius)
            }
        }
    }

    /// 红「房」字标（和主位空位那个「房」标同色同形，视觉上是同一个东西）
    private var hostTag: some View {
        Text("房")
            .font(.system(size: max(7.5, size * 0.72), weight: .heavy))
            .foregroundColor(.white)
            .frame(width: max(13, size * 1.3), height: max(13, size * 1.3))
            .background(Circle().fill(VRTheme.hostRed))
            // 别被外面那层 lineLimit / minimumScaleFactor 压扁
            .fixedSize()
    }

    private var glowColor: Color { tier.glow(onLight: onLight)?.0 ?? .clear }
    private var glowRadius: CGFloat { tier.glow(onLight: onLight)?.1 ?? 0 }

    /// 一道白光横着扫过。用 mask 把光限制在字形里 —— 否则就是一块白条糊在名字上。
    @ViewBuilder
    private var shineLayer: some View {
        if tier.shinePeriod != nil {
            GeometryReader { geo in
                let w = geo.size.width
                LinearGradient(colors: [Color.white.opacity(0),
                                        Color.white.opacity(0.95),
                                        Color.white.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: max(10, w * 0.45))
                    .offset(x: shine * w)
            }
            .mask(
                Text(name)
                    .font(font)
                    .lineLimit(lineLimit)
            )
            .allowsHitTesting(false)
        }
    }

    private func startShine() {
        guard let period = tier.shinePeriod else { return }
        // 视图被复用/重新出现时进度可能已经停在终点，先复位再起动画，否则"闪一次就不动了"
        shine = -0.6
        withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) {
            shine = 1.2
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
