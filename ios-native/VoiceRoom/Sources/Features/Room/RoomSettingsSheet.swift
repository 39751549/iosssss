import SwiftUI
import UIKit

/// 房间设置（房主可改房间名 / 背景）
struct RoomSettingsSheet: View {

    let state: VRRoomState

    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var roomName = ""
    @State private var background: RoomBackground = RoomBackground.fallback
    /// 用户本次是否**主动点过**内置背景瓦片。
    ///
    /// 为什么需要这个标记：房间用的是上传的自定义背景时，
    /// 瓦片里没有一个能对上当前背景，选中态只能落在默认那张上。
    /// 若不加区分，"进设置 → 什么都不改直接点保存" 会因为
    /// `background.id("/presets/preset-1.gif") != state.room.background("/bg/bg_xxx.gif")` 成立，
    /// 而把刚上传的自定义背景又覆盖回内置图 —— 表现就是「自定义背景设了没用 / 一会儿就没了」。
    @State private var themePicked = false
    @State private var showDestroyConfirm = false
    @State private var customNo = ""
    @State private var showBgPicker = false
    @State private var isUploadingBg = false

    private var isHost: Bool { app.isHost }
    private var isVip: Bool { app.me?.vip == true }

    /// 当前房间是否用了上传的自定义背景（内置的 5 张不算）
    private var isCustomBg: Bool {
        RoomBackground.isCustom(state.room.background)
    }

    var body: some View {
        ZStack {
            VRTheme.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("房间设置")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(VRTheme.text)

                    // 房间号
                    VStack(alignment: .leading, spacing: 7) {
                        Text("房间号（点一下复制）")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(VRTheme.textDim)

                        Button {
                            UIPasteboard.general.string = state.room.no
                            app.showToast("房间号已复制：\(state.room.no)", kind: .success)
                        } label: {
                            HStack {
                                Text(state.room.no)
                                    .font(.system(size: 21, weight: .heavy, design: .monospaced))
                                    .foregroundColor(VRTheme.gold)
                                    .tracking(2)
                                Spacer()
                                Text("📋 复制")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(VRTheme.textDim)
                            }
                            .padding(.horizontal, 15)
                            .frame(height: 52)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color(hex: "27436B").opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(VRTheme.border, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // 自定义房间号（VIP 房主专属）
                    if isHost && isVip {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 6) {
                                Text("自定义房间号")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(VRTheme.textDim)
                                Text("💎 VIP 专属")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(VRTheme.gold)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(VRTheme.gold.opacity(0.14)))
                            }
                            HStack(spacing: 9) {
                                VRTextField(placeholder: "4-10 位数字或字母", text: $customNo, maxLength: 10)
                                Button("改号") {
                                    let v = customNo.trimmingCharacters(in: .whitespaces).uppercased()
                                    guard !v.isEmpty else {
                                        app.showToast("请输入新房间号", kind: .error)
                                        return
                                    }
                                    app.setRoomNo(v)
                                }
                                .buttonStyle(VRButtonStyle(kind: .primary))
                            }
                            Text("改完立即生效并永久保存，好友用新房间号就能进房。")
                                .font(.system(size: 11))
                                .foregroundColor(VRTheme.textMute)
                        }
                    }

                    // 房间名
                    VStack(alignment: .leading, spacing: 7) {
                        Text("房间名称")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(VRTheme.textDim)
                        VRTextField(placeholder: "房间名称", text: $roomName, maxLength: 22)
                            .disabled(!isHost)
                            .opacity(isHost ? 1 : 0.55)
                    }

                    // 背景
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Text("房间背景")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(VRTheme.textDim)
                            Spacer()
                            // 上传自定义背景（支持 GIF 动图，永久生效）
                            Button {
                                showBgPicker = true
                            } label: {
                                Text("🖼️ 上传自定义")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(VRTheme.text)
                                    .padding(.horizontal, 11)
                                    .frame(height: 30)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color(hex: "27436B").opacity(0.1))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(VRTheme.border, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .disabled(!isHost)
                            .opacity(isHost ? 1 : 0.45)
                        }

                        if isUploadingBg {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.8)
                                Text("正在上传背景…")
                                    .font(.system(size: 12))
                                    .foregroundColor(VRTheme.textDim)
                            }
                        }

                        // 已设置自定义背景：预览 + 清除
                        if isCustomBg {
                            HStack(spacing: 10) {
                                ZStack {
                                    Color(hex: "27436B").opacity(0.08)
                                    if let img = app.roomBackgroundImage {
                                        GIFImageView(image: img, contentMode: .scaleAspectFill)
                                            .frame(width: 54, height: 54)
                                    }
                                }
                                .frame(width: 54, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("自定义背景已生效")
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .foregroundColor(VRTheme.green)
                                    Text("支持 GIF 动图 · 永久保存 · 全房可见")
                                        .font(.system(size: 10.5))
                                        .foregroundColor(VRTheme.textMute)
                                }
                                Spacer()
                                Button("清除") {
                                    themePicked = false
                                    background = RoomBackground.fallback
                                    app.setRoomBackground(RoomBackground.fallback)
                                    app.showToast("已恢复默认背景", kind: .success)
                                }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(VRTheme.red.opacity(0.9))
                            }
                            .padding(11)
                            .background(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(VRTheme.green.opacity(0.08))
                            )
                        }

                        Text("内置背景（固定 5 张）")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(VRTheme.textMute)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3),
                                  spacing: 9) {
                            ForEach(RoomBackground.presets) { bg in
                                BackgroundOption(bg: bg, selected: !isCustomBg && background == bg) {
                                    guard isHost else {
                                        app.showToast("只有房主能修改房间背景", kind: .error)
                                        return
                                    }
                                    withAnimation(.easeOut(duration: 0.16)) {
                                        background = bg
                                        themePicked = true   // 明确表达"我要换成这张"
                                    }
                                }
                            }
                        }

                        if let g = state.globalBg, !g.isEmpty {
                            Text("💡 管理员已设置全局背景模板，所有房间通用；上传自定义背景可覆盖它。")
                                .font(.system(size: 11))
                                .foregroundColor(VRTheme.textMute)
                        }
                    }

                    Button("保存") {
                        let n = roomName.trimmingCharacters(in: .whitespaces)
                        if !n.isEmpty && n != state.room.name { app.renameRoom(n) }
                        // 只有用户真的点了某张内置背景瓦片才覆盖背景。
                        // 这样"上传了自定义背景 → 进来改个房间名 → 保存"不会把背景图reset掉。
                        if themePicked, background.id != state.room.background {
                            app.setRoomBackground(background)
                        }
                        // 改完主动拉一次快照：房间名/背景立刻反映到房间里，
                        // 不用等被动推送（以前表现为"必须退出房间重进才生效"）
                        app.requestRoomSync()
                        app.showToast("房间设置已保存", kind: .success)
                        dismiss()
                    }
                    .buttonStyle(VRButtonStyle(kind: .primary, fullWidth: true))
                    .disabled(!isHost)
                    .opacity(isHost ? 1 : 0.45)

                    if !isHost {
                        Text("只有房主能修改房间名和背景。你可以把房间号发给朋友，邀请他们进来。")
                            .font(.system(size: 12))
                            .foregroundColor(VRTheme.textMute)
                            .padding(11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(hex: "27436B").opacity(0.05))
                            )
                    }

                    // 危险操作
                    VStack(alignment: .leading, spacing: 10) {
                        Text("其他")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(VRTheme.textDim)

                        Button("🚪 离开房间") {
                            app.leaveRoom()
                            dismiss()
                        }
                        .buttonStyle(VRButtonStyle(fullWidth: true))

                        if isHost {
                            Button {
                                showDestroyConfirm = true
                            } label: {
                                Text("💣 解散我的永久房间")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity, minHeight: 46)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(LinearGradient(colors: [Color(hex: "E0344C"), Color(hex: "A81C3C")],
                                                                 startPoint: .leading, endPoint: .trailing))
                                    )
                                    .shadow(color: Color(hex: "E0344C").opacity(0.35), radius: 10, y: 4)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 2)
                        }
                    }
                }
                .padding(20)
            }
            .vrScrollHidden()
        }
        .confirmationDialog("解散后房间将永久删除，房间里的所有人都会被请出。确定吗？",
                            isPresented: $showDestroyConfirm, titleVisibility: .visible) {
            Button("解散房间", role: .destructive) {
                app.destroyMyRoom()
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
        .vrSheet()
        .sheet(isPresented: $showBgPicker) {
            VRPhotoPicker { img, raw in
                uploadBackground(img: img, raw: raw)
            }
        }
        .onAppear {
            roomName = state.room.name
            background = RoomBackground.resolved(state.room.background)
        }
        .onDisappear {
            // 面板关掉（保存 / ✕ / 下滑）都补拉一次快照：
            // 保证回到房间时背景、房间名、成员都是最新的，不必退出房间重进
            app.requestRoomSync()
        }
    }

    /// 上传房间自定义背景（支持 GIF 动图；服务端存文件，永久生效）
    private func uploadBackground(img: UIImage, raw: Data?) {
        guard isHost else {
            app.showToast("只有房主能修改房间背景", kind: .error)
            return
        }
        isUploadingBg = true

        // 生成 dataURL：GIF 保留动画，PNG 保留透明，其余转 JPEG
        var dataURL: String?
        if let raw, let kind = imageKind(raw), kind == "gif", raw.count <= 6 * 1024 * 1024 {
            dataURL = "data:image/gif;base64," + raw.base64EncodedString()
        } else if let raw, let kind = imageKind(raw), kind == "png",
                  let png = img.resized(maxSide: 1440).pngData(), png.count < 5 * 1024 * 1024 {
            dataURL = "data:image/png;base64," + png.base64EncodedString()
        } else {
            let jpeg = img.resized(maxSide: 1440).jpegData(compressionQuality: 0.86)
            if let jpeg, jpeg.count < 5 * 1024 * 1024 {
                dataURL = "data:image/jpeg;base64," + jpeg.base64EncodedString()
            }
        }

        guard let durl = dataURL else {
            isUploadingBg = false
            app.showToast("图片太大了，换张小一点的吧", kind: .error)
            return
        }

        BGUploader.upload(dataURL: durl, userId: app.userId) { result in
            isUploadingBg = false
            switch result {
            case .success(let url):
                // 清掉"点过主题"的标记，防止紧接着点保存时又被内置主题覆盖。
                themePicked = false
                // 本机已经有这张图了 → 立刻应用，既不等服务端快照、也不用再下载一次。
                // （否则用户点完"上传"要盯着默认主题等图片下完，体感就是"设置了半天不生效"。）
                // GIF 用原始数据解码（ImageIO）才能拿到动图而不是首帧；
                // 解码放到后台线程：4MB / 50 帧的 GIF 在主线程解会明显卡住界面。
                if let raw {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let preview = MediaCache.decode(raw, profile: .background) ?? img
                        DispatchQueue.main.async {
                            app.applyRoomBackground(path: url, image: preview)
                            app.requestRoomSync()
                        }
                    }
                } else {
                    app.applyRoomBackground(path: url, image: img)
                    app.requestRoomSync()
                }
                app.showToast("背景已应用，永久生效 ✨", kind: .success)
            case .failure(let err):
                app.showToast("上传失败：\(err.localizedDescription)", kind: .error)
            }
        }
    }

    private func imageKind(_ data: Data) -> String? {
        guard data.count >= 8 else { return nil }
        let b = [UInt8](data.prefix(8))
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return "gif" }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
        return "other"
    }
}

// MARK: - 背景上传

/// 房间背景上传（dataURL → /api/upload-bg）
enum BGUploader {
    static func upload(dataURL: String, userId: String,
                       completion: @escaping (Result<String, Error>) -> Void) {
        guard let base = VRConfig.baseURL else {
            completion(.failure(VRAPIError.noServer)); return
        }
        var req = URLRequest(url: base.appendingPathComponent("api/upload-bg"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 60
        let body: [String: Any] = ["userId": userId, "dataUrl": dataURL]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, _, err in
            DispatchQueue.main.async {
                if let err { completion(.failure(err)); return }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.failure(VRAPIError.empty)); return
                }
                if let ok = json["ok"] as? Bool, ok, let url = json["url"] as? String {
                    completion(.success(url))
                } else {
                    let msg = json["msg"] as? String ?? "上传失败"
                    completion(.failure(NSError(domain: "bg", code: -1,
                                                userInfo: [NSLocalizedDescriptionKey: msg])))
                }
            }
        }.resume()
    }
}
