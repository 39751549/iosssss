import SwiftUI
import ImageIO
import UniformTypeIdentifiers

/// 编辑名片弹层
struct ProfileEditSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var gender: Gender = .secret
    @State private var bio = ""
    @State private var avatar: String = ""

    // 相册选择（VRPhotoPicker：iOS 15 兼容）
    @State private var showPhotoPicker = false
    @State private var previewImage: UIImage?
    @State private var isProcessing = false

    var body: some View {
        ZStack {
            VRTheme.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("编辑我的名片")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(VRTheme.text)

                    // 头像
                    HStack(spacing: 16) {
                        ZStack {
                            if let previewImage {
                                Image(uiImage: previewImage)
                                    .resizable().scaledToFill()
                                    .frame(width: 74, height: 74)
                                    .clipShape(Circle())
                            } else {
                                VRAvatarFull(user: previewUser, size: 74)
                            }
                            if isProcessing {
                                Circle().fill(.black.opacity(0.5)).frame(width: 74, height: 74)
                                ProgressView().tint(.white).scaleEffect(0.8)
                            }
                        }
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)

                        VStack(alignment: .leading, spacing: 9) {
                            Button {
                                showPhotoPicker = true
                            } label: {
                                Label("从相册选择", systemImage: "photo")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(VRTheme.text)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 36)
                                    .background(
                                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .fill(Color(hex: "27436B").opacity(0.1))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .strokeBorder(VRTheme.border, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)

                            Button {
                                randomAvatar()
                            } label: {
                                Text("🎲 随机生成")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(VRTheme.text)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 36)
                                    .background(
                                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .fill(Color(hex: "27436B").opacity(0.1))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .strokeBorder(VRTheme.border, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // 昵称
                    VStack(alignment: .leading, spacing: 7) {
                        Text("昵称").font(.system(size: 12.5, weight: .semibold)).foregroundColor(VRTheme.textDim)
                        VRTextField(placeholder: "昵称", text: $name, maxLength: 20)
                    }

                    // 性别
                    VStack(alignment: .leading, spacing: 7) {
                        Text("性别").font(.system(size: 12.5, weight: .semibold)).foregroundColor(VRTheme.textDim)
                        VRSegmentedControl(
                            options: [(Gender.male, "♂ 男生"), (.female, "♀ 女生"), (.secret, "保密")],
                            selection: $gender
                        )
                    }

                    // 签名
                    VStack(alignment: .leading, spacing: 7) {
                        Text("个性签名").font(.system(size: 12.5, weight: .semibold)).foregroundColor(VRTheme.textDim)
                        VRTextField(placeholder: "说点什么吧（最多 60 字）", text: $bio, maxLength: 60)
                    }

                    Button("保存名片") {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        guard !n.isEmpty else {
                            app.showToast("昵称不能为空", kind: .error); return
                        }
                        app.updateProfile(name: n, gender: gender, bio: bio, avatar: avatar)
                        dismiss()
                    }
                    .buttonStyle(VRButtonStyle(kind: .primary, fullWidth: true))
                }
                .padding(20)
            }
        }
        .vrSheet()
        .onAppear(perform: loadCurrent)
        .sheet(isPresented: $showPhotoPicker) {
            VRPhotoPicker { img, raw in
                handlePicked(img, originalData: raw)
            }
        }
        .onChange(of: name) { _ in
            // 昵称变了，若用的是生成头像则同步刷新
            if previewImage == nil { previewImage = nil }
        }
    }

    /// 预览用的临时用户对象
    private var previewUser: VRUser {
        var u = app.me ?? VRUser.placeholder()
        u.name = name.isEmpty ? (app.me?.name ?? "?") : name
        if !avatar.isEmpty { u.avatar = avatar }
        return u
    }

    private func loadCurrent() {
        guard let me = app.me else { return }
        name = me.name
        gender = me.gender
        bio = me.bio
        avatar = me.avatar
        // 若头像是 dataURL，解析成 UIImage 用于预览
        if me.avatar.hasPrefix("data:image"), let range = me.avatar.range(of: "base64,") {
            let b64 = String(me.avatar[range.upperBound...])
            if let data = Data(base64Encoded: b64) { previewImage = UIImage(data: data) }
        }
    }

    private func randomAvatar() {
        // 清空自定义头像，让服务端/本地按昵称生成一个
        avatar = ""
        previewImage = nil
        app.showToast("已切换为生成头像（首字母 + 渐变色）")
    }

    /// 处理相册选图。
    ///
    /// 关键：**保留透明通道与 GIF 动画**。
    /// 旧实现无条件转 JPEG → 透明背景变黑、GIF 只剩第一帧。
    /// 现在按原图类型分派：GIF 原样上传（保动画），PNG 保透明，其余才转 JPEG。
    private func handlePicked(_ image: UIImage, originalData: Data?) {
        isProcessing = true
        defer { isProcessing = false }

        // 1) GIF：原样上传（动画帧完整保留）；过大时不再压缩帧，只做尺寸限制
        if let data = originalData, let kind = imageKind(data), kind == .gif {
            if data.count <= 3 * 1024 * 1024 {
                previewImage = animatedImage(from: data) ?? image
                avatar = "data:image/gif;base64," + data.base64EncodedString()
                app.showToast("GIF 动图已就绪 🎬", kind: .success)
                return
            }
            // GIF 太大：仅缩放尺寸（仍保持 GIF 编码）
            let resized = image.resized(maxSide: 240)
            if let gifData = resized.gifData(), gifData.count <= 6 * 1024 * 1024 {
                previewImage = animatedImage(from: gifData) ?? resized
                avatar = "data:image/gif;base64," + gifData.base64EncodedString()
                app.showToast("GIF 已压缩后上传 🎬", kind: .success)
                return
            }
            app.showToast("这张 GIF 太大了，换张小一点的吧", kind: .error)
            return
        }

        // 2) PNG：保留透明通道（不转 JPEG）
        if let data = originalData, imageKind(data) == .png {
            let resized = image.resized(maxSide: 256)
            if let png = resized.pngData(), png.count <= 3 * 1024 * 1024 {
                previewImage = resized
                avatar = "data:image/png;base64," + png.base64EncodedString()
                app.showToast("透明头像已就绪 ✨", kind: .success)
                return
            }
            // PNG 过大 → 仍保 PNG（有 alpha 时不能转 JPEG）
            let smaller = image.resized(maxSide: 200)
            if let png = smaller.pngData() {
                previewImage = smaller
                avatar = "data:image/png;base64," + png.base64EncodedString()
                return
            }
        }

        // 3) 其余（HEIC/JPEG 等无透明需求）：JPEG 压缩
        let resized = image.resized(maxSide: 256)
        guard let jpeg = resized.jpegData(compressionQuality: 0.82) else {
            app.showToast("图片处理失败", kind: .error)
            return
        }
        previewImage = resized
        avatar = "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }

    private enum ImageKind { case gif, png, other }

    private func imageKind(_ data: Data) -> ImageKind? {
        guard data.count >= 8 else { return .other }
        let b = [UInt8](data.prefix(8))
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return .gif }         // GIF8
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return .png } // PNG
        return .other
    }

    private func animatedImage(from data: Data) -> UIImage? {
        // 必须走 MediaCache.decode（ImageIO），UIImage(data:) 对 GIF 只取首帧
        return MediaCache.decode(data)
    }
}

// MARK: - UIImage 缩放 / GIF 编码

extension UIImage {
    func resized(maxSide: CGFloat) -> UIImage {
        // 动图：逐帧缩放后重组，保留动画（否则会塌成 1 帧）
        if let animFrames = images, animFrames.count > 1 {
            let scaled = animFrames.map { $0.resizedSingle(maxSide: maxSide) }
            return UIImage.animatedImage(with: scaled, duration: duration) ?? scaled[0]
        }
        return resizedSingle(maxSide: maxSide)
    }

    private func resizedSingle(maxSide: CGFloat) -> UIImage {
        let longSide = max(size.width, size.height)
        guard longSide > maxSide else { return self }
        let scale = maxSide / longSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        // 保留透明通道（opaque: false）
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// 把当前图编码为 GIF；多帧动图会保留全部帧与每帧延时
    func gifData() -> Data? {
        let data = NSMutableData()
        let frameImages = images ?? [self]
        guard let dest = CGImageDestinationCreateWithData(
            data, "com.compuserve.gif" as CFString, frameImages.count, nil) else {
            return nil
        }
        let frameDelay = duration > 0 && frameImages.count > 1
            ? duration / Double(frameImages.count) : 0.1
        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime: frameDelay,
            ] as [CFString: Any],
        ]
        // 首帧写入循环次数（0 = 无限循环）
        let loopProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0] as [CFString: Any],
        ]
        for (i, img) in frameImages.enumerated() {
            guard let cg = img.cgImage else { continue }
            let props = (i == 0) ? merged(frameProps, loopProps) : frameProps
            CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private func merged(_ a: [CFString: Any], _ b: [CFString: Any]) -> [CFString: Any] {
        var out = a
        for (k, v) in b {
            if k == kCGImagePropertyGIFDictionary,
               let av = out[k] as? [CFString: Any], let bv = v as? [CFString: Any] {
                out[k] = av.merging(bv) { _, new in new }
            } else { out[k] = v }
        }
        return out
    }
}
