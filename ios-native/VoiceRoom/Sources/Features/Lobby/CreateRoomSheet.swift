import SwiftUI

/// 创建房间弹层
struct CreateRoomSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var roomName = ""
    @State private var background: RoomBackground = .aurora

    var body: some View {
        ZStack {
            VRTheme.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("创建房间")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(VRTheme.text)

                    VStack(alignment: .leading, spacing: 7) {
                        Text("房间名称")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(VRTheme.textDim)
                        VRTextField(placeholder: "给房间起个名字", text: $roomName, maxLength: 22)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("房间背景")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(VRTheme.textDim)

                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 3),
                                  spacing: 9) {
                            ForEach(RoomBackground.allCases) { bg in
                                BackgroundOption(bg: bg, selected: background == bg) {
                                    withAnimation(.easeOut(duration: 0.16)) { background = bg }
                                }
                            }
                        }
                    }

                    Button("创建并进入") {
                        let name = roomName.trimmingCharacters(in: .whitespaces)
                        app.createRoom(name: name.isEmpty ? "\(app.me?.name ?? "我") 的房间" : name,
                                       background: background)
                        dismiss()
                    }
                    .buttonStyle(VRButtonStyle(kind: .primary, fullWidth: true))

                    Text("创建后会生成一个 6 位房间号，把它发给朋友就能一起进来。")
                        .font(.system(size: 12))
                        .foregroundColor(VRTheme.textMute)
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.05))
                        )
                }
                .padding(20)
            }
        }
        .vrSheet()
        .onAppear {
            if roomName.isEmpty {
                roomName = "\(app.me?.name ?? "我") 的房间"
            }
        }
    }
}

/// 背景选项卡片
struct BackgroundOption: View {
    let bg: RoomBackground
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(colors: VRTheme.background(for: bg.rawValue),
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(height: 76)

                Text(bg.label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.42))

                if selected {
                    VStack {
                        HStack {
                            Spacer()
                            ZStack {
                                Circle().fill(VRTheme.brand).frame(width: 19, height: 19)
                                Text("✓").font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                            }
                        }
                        Spacer()
                    }
                    .padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(selected ? VRTheme.brand : .clear, lineWidth: 2)
            )
            .shadow(color: selected ? VRTheme.brand.opacity(0.3) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
    }
}

/// VIP 激活弹层
struct VipSheet: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""

    var body: some View {
        ZStack {
            VRTheme.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Text("👑").font(.system(size: 28))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("VIP 激活")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundColor(VRTheme.text)
                        Text(app.me?.vip == true ? "当前已是 VIP\(app.me?.vipLevel ?? 1)" : "输入 VIP 码即可激活")
                            .font(.system(size: 12.5))
                            .foregroundColor(VRTheme.textDim)
                    }
                }

                VRTextField(placeholder: "输入 VIP 码", text: $code, maxLength: 20)

                Button("立即激活") {
                    let c = code.trimmingCharacters(in: .whitespaces)
                    guard !c.isEmpty else {
                        app.showToast("请输入 VIP 码", kind: .error); return
                    }
                    app.activateVip(code: c)
                    dismiss()
                }
                .buttonStyle(VRButtonStyle(kind: .gold, fullWidth: true))

                VStack(alignment: .leading, spacing: 7) {
                    Text("VIP 权益")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(VRTheme.text)
                    Text("· 金色皇冠标识，全房间可见\n· 专属会员徽章\n· 激活即赠 5000 金币")
                        .font(.system(size: 12.5))
                        .foregroundColor(VRTheme.textDim)
                        .lineSpacing(4)
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )

                Spacer()
            }
            .padding(20)
        }
        .vrSheet(medium: true, large: true)
    }
}
