import SwiftUI

/// 大厅页：昵称资料条 + 加入房间 + 房间列表
struct LobbyView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var serverStore: ServerStore

    @State private var joinNo = ""
    @State private var showCreate = false
    @State private var showProfile = false
    @State private var showVip = false
    @State private var showServer = false
    @State private var showDestroyConfirm = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: "D6EEFF"), Color(hex: "EAF6FF"), Color(hex: "FFF4E8")],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            .overlay(
                RadialGradient(colors: [Color(hex: "FFD9EC").opacity(0.45), .clear],
                               center: .init(x: 0.2, y: 0.05), startRadius: 0, endRadius: 340)
                .ignoresSafeArea()
            )

            ScrollView {
                VStack(spacing: 14) {
                    profileCard
                    joinCard
                    myRoomCard
                    roomListCard
                    otherCard

                    Text("长按桌面图标可添加到主屏幕，像 App 一样使用")
                        .font(.system(size: 11.5))
                        .foregroundColor(VRTheme.textMute)
                        .padding(.top, 6)
                        .padding(.bottom, 30)
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
            }
            .refreshable { app.requestRoomList() }
        }
        .sheet(isPresented: $showCreate) {
            CreateRoomSheet().environmentObject(app)
        }
        .sheet(isPresented: $showProfile) {
            ProfileEditSheet().environmentObject(app)
        }
        .sheet(isPresented: $showVip) {
            VipSheet().environmentObject(app)
        }
        .sheet(isPresented: $showServer) {
            ServerSettingsView().environmentObject(serverStore).environmentObject(app)
        }
    }

    // MARK: - 资料卡片

    private var profileCard: some View {
        VRCard {
            VStack(spacing: 14) {
                Button {
                    showProfile = true
                } label: {
                    HStack(spacing: 13) {
                        VRAvatarFull(user: app.me, size: 56)
                            .shadow(color: .black.opacity(0.3), radius: 8, y: 4)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(app.me?.name ?? "—")
                                    .font(.system(size: 16.5, weight: .bold))
                                    .foregroundColor(VRTheme.text)
                                if app.me?.vip == true {
                                    VRBadge(kind: .vip, text: "👑 VIP\(app.me?.vipLevel ?? 1)")
                                }
                            }
                            HStack(spacing: 5) {
                                if let g = app.me?.gender { VRGenderIcon(gender: g) }
                                Text(genderLabel)
                                    .font(.system(size: 12))
                                    .foregroundColor(VRTheme.textDim)
                            }
                        }

                        Spacer()
                        Text("›")
                            .font(.system(size: 20))
                            .foregroundColor(VRTheme.textMute)
                    }
                }
                .buttonStyle(.plain)

                // 金币 / 魅力值 / VIP
                HStack(spacing: 10) {
                    statBox(title: "💰 金币", value: shortNum(app.me?.coins ?? 0), color: VRTheme.gold)
                    statBox(title: "💖 魅力值", value: shortNum(app.me?.charm ?? 0), color: VRTheme.pink)
                    statBox(title: "👑 会员", value: app.me?.vip == true ? "VIP\(app.me?.vipLevel ?? 1)" : "普通",
                            color: VRTheme.brand2)
                }
            }
        }
    }

    private var genderLabel: String {
        guard let g = app.me?.gender else { return "保密" }
        return g.label
    }

    private func statBox(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .heavy))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(VRTheme.textDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(hex: "27436B").opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(VRTheme.border, lineWidth: 1)
        )
    }

    // MARK: - 加入房间

    private var joinCard: some View {
        VRCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("🚪 加入房间")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(VRTheme.text)

                HStack(spacing: 10) {
                    VRTextField(placeholder: "输入 6 位房间号", text: $joinNo,
                                maxLength: 6, keyboard: .numberPad)
                    Button("进入") {
                        guard joinNo.count == 6, joinNo.allSatisfy(\.isNumber) else {
                            app.showToast("请输入 6 位数字房间号", kind: .error)
                            return
                        }
                        app.joinRoom(no: joinNo)
                        joinNo = ""
                    }
                    .buttonStyle(VRButtonStyle(kind: .primary))
                }

                Button("✨ 创建我的房间") { showCreate = true }
                    .buttonStyle(VRButtonStyle(kind: .pink, fullWidth: true))
            }
        }
    }

    // MARK: - 我的永久房间

    private var myRoomCard: some View {
        Group {
            if let room = app.myRoom {
                VRCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("🏠 我的永久房间")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(VRTheme.text)
                            Spacer()
                            Text(room.count > 0 ? "\(room.count) 人在房间" : "空闲中")
                                .font(.system(size: 10.5, weight: .bold))
                                .foregroundColor(room.count > 0 ? VRTheme.green : VRTheme.textMute)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(room.count > 0 ? VRTheme.green.opacity(0.16) : Color(hex: "27436B").opacity(0.08))
                                )
                        }

                        Button { app.joinRoom(id: room.id) } label: {
                            myRoomRow(room)
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 10) {
                            Button {
                                app.joinRoom(id: room.id)
                            } label: {
                                Text("🎙️ 进入我的房间")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity, minHeight: 42)
                                    .background(
                                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                                            .fill(VRTheme.pinkGradient)
                                    )
                                    .shadow(color: VRTheme.pink.opacity(0.35), radius: 10, y: 4)
                            }
                            .buttonStyle(.plain)

                            Button {
                                showDestroyConfirm = true
                            } label: {
                                Text("解散")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(VRTheme.text)
                                    .frame(maxWidth: .infinity, minHeight: 42)
                                    .background(
                                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                                            .fill(Color(hex: "27436B").opacity(0.1))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                                            .strokeBorder(VRTheme.border, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .confirmationDialog("解散后房间将永久删除，房间里的人都会被请出。确定吗？",
                                    isPresented: $showDestroyConfirm, titleVisibility: .visible) {
                    Button("解散房间", role: .destructive) { app.destroyMyRoom(room.id) }
                    Button("取消", role: .cancel) {}
                }
            }
        }
    }

    private func myRoomRow(_ room: VRMyRoom) -> some View {
        HStack(spacing: 12) {
            RoomBackgroundThumb(background: room.background, size: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(room.name.isEmpty ? "我的房间" : room.name)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(VRTheme.text)
                    .lineLimit(1)
                Text("房间号 \(room.no)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(VRTheme.textDim)
            }

            Spacer()

            Text("👑 房主")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundColor(VRTheme.gold)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(VRTheme.gold.opacity(0.15)))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color(hex: "27436B").opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(VRTheme.border, lineWidth: 1)
        )
    }

    // MARK: - 房间列表

    private var roomListCard: some View {
        VRCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("🔥 正在热聊")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(VRTheme.text)
                    Spacer()
                    if app.isLoadingRooms {
                        ProgressView().tint(VRTheme.textDim).scaleEffect(0.7)
                    } else {
                        Text(app.roomList.isEmpty ? "" : "\(app.roomList.count) 个")
                            .font(.system(size: 11.5))
                            .foregroundColor(VRTheme.textMute)
                    }
                    Button {
                        app.requestRoomList()
                    } label: {
                        Text("↻")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(VRTheme.textDim)
                            .frame(width: 28, height: 28)
                    }
                }

                if app.roomList.isEmpty {
                    VStack(spacing: 5) {
                        Text("还没有房间")
                        Text("创建第一个吧 ✨").font(.system(size: 12))
                    }
                    .font(.system(size: 13))
                    .foregroundColor(VRTheme.textMute)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(app.roomList) { room in
                        Button {
                            app.joinRoom(id: room.id)
                        } label: {
                            roomRow(room)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func roomRow(_ room: VRRoomSummary) -> some View {
        HStack(spacing: 12) {
            RoomBackgroundThumb(background: room.background, size: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text(room.name)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(VRTheme.text)
                    .lineLimit(1)
                Text("房间号 \(room.no)")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(VRTheme.textDim)
            }

            Spacer()

            Text(room.count > 0 ? "\(room.count) 人" : "空闲")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundColor(room.count > 0 ? VRTheme.green : VRTheme.textMute)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(room.count > 0 ? VRTheme.green.opacity(0.16) : Color(hex: "27436B").opacity(0.08))
                )
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color(hex: "27436B").opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(VRTheme.border, lineWidth: 1)
        )
    }

    // MARK: - 其他

    private var otherCard: some View {
        VRCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("⚙️ 其他")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(VRTheme.text)

                HStack(spacing: 10) {
                    Button("✏️ 编辑名片") { showProfile = true }
                        .buttonStyle(VRButtonStyle(fullWidth: true))
                    Button("👑 VIP 激活") { showVip = true }
                        .buttonStyle(VRButtonStyle(fullWidth: true))
                }
                HStack(spacing: 10) {
                    Button("🖥️ 服务器设置") { showServer = true }
                        .buttonStyle(VRButtonStyle(fullWidth: true))
                    Button("🔌 重新连接") {
                        app.connection.disconnect()
                        app.connection.connect()
                        app.showToast("正在重连…")
                    }
                    .buttonStyle(VRButtonStyle(fullWidth: true))
                }
            }
        }
    }
}
