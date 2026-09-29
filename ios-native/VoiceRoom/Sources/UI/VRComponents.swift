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

/// 支持 dataURL 的完整头像视图（性能敏感列表用 VRAvatar，detail 页用这个）
struct VRAvatarFull: View {
    let user: VRUser?
    var size: CGFloat = 40

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                VRAvatar(user: user, size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .onAppear(perform: loadIfNeeded)
        .onChange(of: user?.avatar) { _ in
            image = nil
            loadIfNeeded()
        }
    }

    private func loadIfNeeded() {
        guard let s = user?.avatar, s.hasPrefix("data:image"),
              let range = s.range(of: "base64,") else { return }
        let b64 = String(s[range.upperBound...])
        guard let data = Data(base64Encoded: b64) else { return }
        image = UIImage(data: data)
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

struct VRPhotoPicker: UIViewControllerRepresentable {
    var onPicked: (UIImage) -> Void
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
            if let img = info[.originalImage] as? UIImage {
                parent.onPicked(img)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
