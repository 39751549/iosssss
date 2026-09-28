import SwiftUI

/// 登录页
struct LoginView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var serverStore: ServerStore

    @State private var name = ""
    @State private var gender: Gender = .secret
    @State private var vipCode = ""
    @State private var showServerSheet = false

    @FocusState private var nameFocused: Bool

    var body: some View {
        ZStack {
            // 背景
            LinearGradient(
                colors: [Color(hex: "3B2E8F"), Color(hex: "171B45"), Color(hex: "080B1A")],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .overlay(
                RadialGradient(colors: [VRTheme.brand.opacity(0.45), .clear],
                               center: .init(x: 0.25, y: 0.1), startRadius: 0, endRadius: 380)
                .ignoresSafeArea()
            )

            ScrollView {
                VStack(spacing: 0) {
                    // Logo
                    VStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 26, style: .continuous)
                                .fill(VRTheme.brandGradient)
                                .frame(width: 84, height: 84)
                                .shadow(color: VRTheme.brand.opacity(0.5), radius: 22, y: 10)
                            Text("🎙️").font(.system(size: 40))
                        }
                        Text("语音房")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(VRTheme.text)
                        Text("和朋友一起开黑聊天 · 听歌 · 送礼")
                            .font(.system(size: 13.5))
                            .foregroundColor(VRTheme.textDim)
                    }
                    .padding(.top, 60)
                    .padding(.bottom, 30)

                    // 登录卡片
                    VRCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("👋 起个昵称就能进")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(VRTheme.text)

                            VRTextField(placeholder: "输入昵称（最多 20 字）",
                                        text: $name, maxLength: 20)
                                .focused($nameFocused)
                                .submitLabel(.go)
                                .onSubmit(doLogin)

                            VRSegmentedControl(
                                options: [(Gender.male, "♂ 男生"),
                                          (.female, "♀ 女生"),
                                          (.secret, "保密")],
                                selection: $gender
                            )

                            Button("进入大厅", action: doLogin)
                                .buttonStyle(VRButtonStyle(kind: .primary, fullWidth: true))
                                .padding(.top, 4)

                            Text("提示：昵称和资料只保存在你自己的手机上。")
                                .font(.system(size: 12))
                                .foregroundColor(VRTheme.textMute)
                                .padding(11)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.white.opacity(0.05))
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
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(isPresented: $showServerSheet) {
            ServerSettingsView()
                .environmentObject(serverStore)
                .environmentObject(app)
        }
    }

    private func doLogin() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            app.showToast("请输入昵称", kind: .error)
            return
        }
        // 未连上时也允许发送：连接建立后 AppState 会补一次 auth
        if !app.connection.isConnected {
            app.showToast("正在连接服务器…", kind: .info)
        }
        app.login(name: trimmed, gender: gender)
        nameFocused = false
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
        NavigationStack {
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
