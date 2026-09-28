import SwiftUI

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
                                            .fill(Color.white.opacity(0.1))
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
                                            .fill(Color.white.opacity(0.1))
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
            VRPhotoPicker { img in
                handlePicked(img)
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

    /// 处理相册选图：压缩成 256px 的 JPEG dataURL
    private func handlePicked(_ image: UIImage) {
        isProcessing = true
        defer { isProcessing = false }

        let resized = image.resized(maxSide: 256)
        guard let jpeg = resized.jpegData(compressionQuality: 0.82) else {
            app.showToast("图片处理失败", kind: .error)
            return
        }

        previewImage = resized
        avatar = "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }
}

// MARK: - UIImage 缩放

extension UIImage {
    func resized(maxSide: CGFloat) -> UIImage {
        let longSide = max(size.width, size.height)
        guard longSide > maxSide else { return self }
        let scale = maxSide / longSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
