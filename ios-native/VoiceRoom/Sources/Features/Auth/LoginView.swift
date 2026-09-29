import SwiftUI

/// 登录页 —— 账号密码登岛
struct LoginView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var serverStore: ServerStore

    @State private var username = ""
    @State private var password = ""
    @State private var vipCode = ""
    @State private var showServerSheet = false

    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack {
            // 明亮卡通背景：天空蓝 → 奶油白 + 柔光晕
            LinearGradient(
                colors: [Color(hex: "BFE3FF"), Color(hex: "EAF6FF"), Color(hex: "FFF4E8")],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .overlay(
                RadialGradient(colors: [Color(hex: "FFD9EC").opacity(0.55), .clear],
                               center: .init(x: 0.2, y: 0.08), startRadius: 0, endRadius: 360)
                .ignoresSafeArea()
            )
            .overlay(
                RadialGradient(colors: [Color(hex: "FFF3C4").opacity(0.5), .clear],
                               center: .init(x: 0.9, y: 0.25), startRadius: 0, endRadius: 300)
                .ignoresSafeArea()
            )

            ScrollView {
                VStack(spacing: 0) {
                    // Logo
                    VStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .fill(VRTheme.brandGradient)
                                .frame(width: 84, height: 84)
                                .shadow(color: VRTheme.brand.opacity(0.35), radius: 18, y: 8)
                            Text("🏝️").font(.system(size: 40))
                        }
                        Text("岛")
                            .font(.system(size: 30, weight: .heavy))
                            .foregroundColor(VRTheme.text)
                        Text("和朋友一起开黑聊天 · 听歌 · 送礼")
                            .font(.system(size: 13.5))
                            .foregroundColor(VRTheme.textDim)
                    }
                    .padding(.top, 56)
                    .padding(.bottom, 28)

                    // 登录卡片
                    VRCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("👋 登录小岛")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(VRTheme.text)

                            VRTextField(placeholder: "账号（2-24 位字母/数字/中文/_）",
                                        text: $username, maxLength: 24)
                                .focused($fieldFocused)
                                .submitLabel(.next)
                                .onSubmit { fieldFocused = false }

                            VRTextField(placeholder: "密码（新账号将自动注册）",
                                        text: $password, maxLength: 64, secure: true)
                                .submitLabel(.go)
                                .onSubmit(doLogin)

                            Button("上岛 🏝", action: doLogin)
                                .buttonStyle(VRButtonStyle(kind: .primary, fullWidth: true))
                                .padding(.top, 4)

                            Text("提示：默认管理员账号 admin / admin")
                                .font(.system(size: 12))
                                .foregroundColor(VRTheme.textMute)
                                .padding(11)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(VRTheme.brand.opacity(0.08))
                                )
                        }
                    }
                    .padding(.horizontal, 20)

                    // VIP 卡片
                    VRCard {
                        VStack(alignment: .leading, spacing: 13) {
                            Text("👑 我有 VIP 码")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(VRTheme.text)

                            HStack(spacing: 10) {
                                VRTextField(placeholder: "输入 VIP 码",
                                            text: $vipCode, maxLength: 20)
                                Button("激活") {
                                    guard app.isLoggedIn else {
                                        app.showToast("请先进入大厅", kind: .error); return
                                    }
                                    app.activateVip(code: vipCode)
                                }
                                .buttonStyle(VRButtonStyle(kind: .gold))
                            }

                            Text("VIP 可解锁金色名片、专属标识，以及 5000 金币。")
                                .font(.system(size: 12))
                                .foregroundColor(VRTheme.textMute)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                    // 服务器设置入口
                    Button {
                        showServerSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Text("⚙️")
                            Text(serverStore.host.isEmpty ? "未设置服务器" : "服务器：\(serverStore.host)")
                                .lineLimit(1)
                            Text("›")
                        }
                        .font(.system(size: 12.5))
                        .foregroundColor(VRTheme.textMute)
                    }
                    .padding(.top, 22)
                    .padding(.bottom, 40)
                }
            }
            .vrScrollDismissKeyboard()
        }
        .sheet(isPresented: $showServerSheet) {
            ServerSettingsView()
                .environmentObject(serverStore)
                .environmentObject(app)
        }
        .onAppear {
            // 被"另一台设备"顶下线后会回到登录页：预填账号，用户只需补密码，
            // 不用再回忆自己当时注册了什么名字。
            if username.isEmpty, !app.rememberedUsername.isEmpty {
                username = app.rememberedUsername
            }
        }
    }

    private func doLogin() {
        let trimmed = username.trimmingCharacters(in: .whitespaces).lowercased()
        let pass = password
        // 注意：range(of:options:.regularExpression) 是 ICU 正则，Unicode 转义必须用 \u4E00（4 位），
        // 不能用 Swift Regex 的 \u{4E00} 花括号写法（无效正则会让所有输入都被拒）
        let pattern = "^[0-9a-z_\\u4E00-\\u9FA5]{2,24}$"
        guard let _ = trimmed.range(of: pattern, options: .regularExpression) else {
            app.showToast("账号需 2-24 位字母/数字/下划线/中文", kind: .error)
            return
        }
        guard !pass.isEmpty, pass.count <= 64 else {
            app.showToast("请输入密码（最长 64 位）", kind: .error)
            return
        }
        app.login(username: trimmed, password: pass)
        fieldFocused = false
    }
}

// MARK: - 服务器设置

struct ServerSettingsView: View {
    @EnvironmentObject var serverStore: ServerStore
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var useTLS = true

    var body: some View {
        vrNavigationStack {
            ZStack {
                VRTheme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("填写你部署好的服务器地址（不含 http://）。\n例如：your-app.koyeb.app")
                            .font(.system(size: 13))
                            .foregroundColor(VRTheme.textDim)

                        VRTextField(placeholder: "your-app.koyeb.app",
                                    text: $host, maxLength: 120, keyboard: .URL)
                            .textInputAutocapitalization(.never)

                        Toggle(isOn: $useTLS) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("使用 HTTPS / WSS")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(VRTheme.text)
                                Text("线上服务器请开启；本地 http 调试时关闭")
                                    .font(.system(size: 11.5))
                                    .foregroundColor(VRTheme.textMute)
                            }
                        }
                        .tint(VRTheme.brand)

                        Button("保存并重连") {
                            let clean = host.trimmingCharacters(in: .whitespaces)
                                .replacingOccurrences(of: "https://", with: "")
                                .replacingOccurrences(of: "http://", with: "")
                                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            serverStore.host = clean
                            serverStore.useTLS = useTLS
                            app.connection.disconnect()
                            app.connection.connect()
                            app.showToast("已保存，正在重连…", kind: .success)
                            dismiss()
                        }
                        .buttonStyle(VRButtonStyle(kind: .primary, fullWidth: true))

                        if app.isLoggedIn {
                            Text("注意：切换服务器后请重新登录，房间数据不会跨服务器同步。")
                                .font(.system(size: 12))
                                .foregroundColor(VRTheme.textMute)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("服务器设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundColor(VRTheme.brand2)
                }
            }
        }
        .onAppear {
            host = serverStore.host
            useTLS = serverStore.useTLS
        }
    }
}
