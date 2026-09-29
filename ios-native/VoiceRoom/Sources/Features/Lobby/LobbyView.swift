import SwiftUI

/// 大厅：底部三个分组（首页 / 房间 / 设置）
///
/// 以前所有卡片（资料、加入房间、我的房间、房间列表、其他设置）堆在一个 ScrollView 里，
/// 手机上一屏放不下，想"进入我的房间"得先往下翻很久。改成分组之后每页都是单屏布局：
/// 顶栏 + 内容 + 底部分组栏，页面骨架本身不滚动，只有「热门房间」列表在内部滚。
struct LobbyView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var serverStore: ServerStore

    // MARK: - 分组定义

    enum LobbyTab: String, CaseIterable, Identifiable {
        case home, rooms, settings
        var id: String { rawValue }

        var label: String {
            switch self {
            case .home:     return "首页"
            case .rooms:    return "房间"
            case .settings: return "设置"
            }
        }

        var symbol: String {
            switch self {
            case .home:     return "house.fill"
            case .rooms:    return "square.grid.2x2.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    /// 「房间」页内部的两个分段
    enum RoomsSection: Hashable {
        case mine, hot
    }

    @State private var tab: LobbyTab = .home
    @State private var section: RoomsSection = .mine

    @State private var joinNo = ""
    @State private var showCreate = false
    @State private var showProfile = false
    @State private var showVip = false
    @State private var showServer = false
    @State private var showDestroyConfirm = false

    var body: some View {
        ZStack {
            lobbyBackground

            VStack(spacing: 0) {
                header
                content
            }
        }
        // 底部分组栏挂在 safeAreaInset 上：内容区会自动扣掉它的高度，
        // 于是每个分组都不必自己留底部空白，也不会被分组栏压住。
        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
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
        .onAppear {
            // 进大厅就顺手刷一次：房间列表和"我的房间"的在线人数都是别人也会改的数据
            app.requestRoomList()
            app.requestMyRoom()
        }
    }

    // MARK: - 背景

    private var lobbyBackground: some View {
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
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 8) {
            Text(tab == .home ? "岛" : tab.label)
                .font(.system(size: 21, weight: .heavy))
                .foregroundColor(VRTheme.text)

            if tab == .home {
                Text("语音房")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(VRTheme.textMute)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(Color(hex: "27436B").opacity(0.07)))
            }

            Spacer()

            connectionPill
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    /// 连接状态小胶囊：断线时一眼能看出来，不用去设置页翻
    private var connectionPill: some View {
        HStack(spacing: 5) {
            Circle().fill(connectionColor).frame(width: 6, height: 6)
            Text(connectionText)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(VRTheme.textDim)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(0.72)))
        .overlay(Capsule().strokeBorder(VRTheme.border, lineWidth: 1))
    }

    private var connectionColor: Color {
        switch app.connection.status {
        case .connected:  return VRTheme.green
        case .connecting: return VRTheme.gold
        case .failed:     return VRTheme.red
        case .idle:       return VRTheme.textMute
        }
    }

    private var connectionText: String {
        switch app.connection.status {
        case .connected:  return "在线"
        case .connecting: return "连接中"
        case .failed:     return "已断开"
        case .idle:       return "未连接"
        }
    }

    // MARK: - 内容分发

    @ViewBuilder
    private var content: some View {
        if tab == .home {
            homePage
        } else if tab == .rooms {
            roomsPage
        } else {
            settingsPage
        }
    }

    // MARK: - 底部分组栏

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(LobbyTab.allCases) { t in
                Button {
                    guard tab != t else { return }
                    withAnimation(.easeOut(duration: 0.18)) { tab = t }
                    // 切到房间页时刷新一次列表，保证看到的是"此刻"的人气
                    if t == .rooms { app.requestRoomList() }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.symbol)
                            .font(.system(size: 17, weight: .semibold))
                        Text(t.label)
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundColor(tab == t ? VRTheme.brand : VRTheme.textMute)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
        .background(
            Color.white.opacity(0.92)
                .background(.ultraThinMaterial)
                .ignoresSafeArea(edges: .bottom)
        )
        .overlay(
            Rectangle()
                .fill(VRTheme.border)
                .frame(height: 1),
            alignment: .top
        )
    }

    // MARK: - 首页（资料 + 我的房间 + 加入房间）

    private var homePage: some View {
        VStack(spacing: 12) {
            profileCard
            myRoomQuickCard
            joinCard
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private var profileCard: some View {
        VRCard {
            VStack(spacing: 14) {
                Button {
                    showProfile = true
                } label: {
                    HStack(spacing: 13) {
                        VRAvatarFull(user: app.me, size: 56,
                                     isMine: true,
                                     vipLevel: app.me?.vip == true ? (app.me?.vipLevel ?? 1) : 0,
                                     showNeutralRing: true)
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

                HStack(spacing: 10) {
                    statBox(title: "💰 金币", value: shortNum(app.me?.coins ?? 0), color: VRTheme.gold)
                    statBox(title: "💖 魅力值", value: shortNum(app.me?.charm ?? 0), color: VRTheme.pink)
                    statBox(title: "👑 会员",
                            value: app.me?.vip == true ? "VIP\(app.me?.vipLevel ?? 1)" : "普通",
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

    /// 我的房间：一键回房（已经在房里时走 resumeCurrentRoom，不会重新进房）
    @ViewBuilder
    private var myRoomQuickCard: some View {
        if let room = app.myRoom {
            VRCard(padding: 14) {
                VStack(spacing: 11) {
                    HStack(spacing: 11) {
                        RoomBackgroundThumb(background: room.background, size: 44)

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

                        RoomCountTag(count: room.count)
                    }

                    Button {
                        app.joinRoom(id: room.id)
                    } label: {
                        Text(app.inRoom && app.roomState?.room.id == room.id
                             ? "🎙️ 回到我的房间"
                             : (room.count > 0 ? "🎙️ 进入我的房间" : "🎙️ 打开我的房间"))
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(VRTheme.pinkGradient)
                            )
                            .shadow(color: VRTheme.pink.opacity(0.32), radius: 9, y: 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            VRCard(padding: 14) {
                VStack(spacing: 11) {
                    HStack(spacing: 11) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 13, style: .continuous)
                                .fill(Color(hex: "27436B").opacity(0.06))
                            Text("🏝️").font(.system(size: 20))
                        }
                        .frame(width: 44, height: 44)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("还没有自己的房间")
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundColor(VRTheme.text)
                            Text("房间是永久的，房间号也归你")
                                .font(.system(size: 11.5))
                                .foregroundColor(VRTheme.textDim)
                        }

                        Spacer()
                    }

                    Button("✨ 创建我的房间") { showCreate = true }
                        .buttonStyle(VRButtonStyle(kind: .pink, fullWidth: true))
                }
            }
        }
    }

    private var joinCard: some View {
        VRCard(padding: 16) {
            VStack(alignment: .leading, spacing: 11) {
                Text("🚪 输入房间号加入")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundColor(VRTheme.text)

                HStack(spacing: 10) {
                    VRTextField(placeholder: "6 位房间号", text: $joinNo,
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
            }
        }
    }

    // MARK: - 房间页（我的房间 / 热门房间）

    private var roomsPage: some View {
        VStack(spacing: 12) {
            VRSegmentedControl(options: [(value: RoomsSection.mine, label: "我的房间"),
                                         (value: RoomsSection.hot, label: "热门房间")],
                               selection: $section)

            if section == .mine {
                mineRoomPanel
            } else {
                hotRoomsPanel
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var mineRoomPanel: some View {
        if let room = app.myRoom {
            VStack(spacing: 12) {
                VRCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            Text("🏠 我的永久房间")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(VRTheme.text)
                            Spacer()
                            RoomCountTag(count: room.count)
                        }

                        Button { app.joinRoom(id: room.id) } label: {
                            HStack(spacing: 12) {
                                RoomBackgroundThumb(background: room.background, size: 52)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(room.name.isEmpty ? "我的房间" : room.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(VRTheme.text)
                                        .lineLimit(1)
                                    Text("房间号 \(room.no) · 永久保留")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(VRTheme.textDim)
                                }

                                Spacer()

                                Text("👑")
                                    .font(.system(size: 15))
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
                        .buttonStyle(.plain)

                        HStack(spacing: 10) {
                            Button {
                                app.joinRoom(id: room.id)
                            } label: {
                                Text("🎙️ 进入房间")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .background(
                                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                                            .fill(VRTheme.pinkGradient)
                                    )
                                    .shadow(color: VRTheme.pink.opacity(0.32), radius: 9, y: 4)
                            }
                            .buttonStyle(.plain)

                            Button {
                                showDestroyConfirm = true
                            } label: {
                                Text("解散")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(VRTheme.text)
                                    .frame(width: 84)
                                    .frame(minHeight: 44)
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

                Spacer(minLength: 0)
            }
        } else {
            VStack(spacing: 12) {
                VRCard(padding: 20) {
                    VStack(spacing: 12) {
                        Text("🏝️").font(.system(size: 38))
                        Text("还没有自己的房间")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(VRTheme.text)
                        Text("创建后房间永久保留，房间号固定不变，\n随时回来都有个自己的地方")
                            .font(.system(size: 12))
                            .foregroundColor(VRTheme.textDim)
                            .multilineTextAlignment(.center)
                        Button("✨ 创建我的房间") { showCreate = true }
                            .buttonStyle(VRButtonStyle(kind: .pink, fullWidth: true))
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// 热门房间：列表占满剩余高度，**只有列表内部滚动**，页面骨架不动
    private var hotRoomsPanel: some View {
        VStack(spacing: 9) {
            HStack {
                Text(app.roomList.isEmpty ? "暂无房间" : "🔥 正在热聊 · \(app.roomList.count) 个")
                    .font(.system(size: 12))
                    .foregroundColor(VRTheme.textDim)

                Spacer()

                if app.isLoadingRooms {
                    ProgressView().tint(VRTheme.textDim).scaleEffect(0.7)
                } else {
                    Button {
                        app.requestRoomList()
                    } label: {
                        HStack(spacing: 3) {
                            Text("↻").font(.system(size: 13, weight: .semibold))
                            Text("刷新").font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundColor(VRTheme.brand)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(VRTheme.brand.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)

            ScrollView {
                LazyVStack(spacing: 8) {
                    if app.roomList.isEmpty {
                        VStack(spacing: 6) {
                            Text("还没有房间")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundColor(VRTheme.textDim)
                            Text("成为第一个开房的人 ✨")
                                .font(.system(size: 12))
                                .foregroundColor(VRTheme.textMute)
                            Button("✨ 创建我的房间") { showCreate = true }
                                .buttonStyle(VRButtonStyle(kind: .pink))
                                .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 34)
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
                .padding(.horizontal, 2)
                .padding(.bottom, 4)
            }
            .vrScrollHidden()
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func roomRow(_ room: VRRoomSummary) -> some View {
        HStack(spacing: 11) {
            RoomBackgroundThumb(background: room.background, size: 44)

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

            RoomCountTag(count: room.count)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(VRTheme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(VRTheme.border, lineWidth: 1)
        )
    }

    // MARK: - 设置页

    private var settingsPage: some View {
        VStack(spacing: 12) {
            VRCard(padding: 16) {
                VStack(alignment: .leading, spacing: 11) {
                    sectionTitle("👤 账号")
                    Button("✏️ 编辑名片") { showProfile = true }
                        .buttonStyle(VRButtonStyle(fullWidth: true))
                    Button("👑 VIP 激活") { showVip = true }
                        .buttonStyle(VRButtonStyle(fullWidth: true))
                }
            }

            VRCard(padding: 16) {
                VStack(alignment: .leading, spacing: 11) {
                    sectionTitle("🔧 连接")
                    Button("🖥️ 服务器设置") { showServer = true }
                        .buttonStyle(VRButtonStyle(fullWidth: true))

                    HStack(spacing: 10) {
                        Button("🔌 重新连接") {
                            app.connection.disconnect()
                            app.connection.connect()
                            app.showToast("正在重连…")
                        }
                        .buttonStyle(VRButtonStyle(fullWidth: true))

                        Button("🔄 刷新数据") {
                            app.requestRoomList()
                            app.requestMyRoom()
                            app.showToast("已刷新", kind: .success)
                        }
                        .buttonStyle(VRButtonStyle(fullWidth: true))
                    }

                    HStack(spacing: 6) {
                        Circle()
                            .fill(currentServerDotColor)
                            .frame(width: 6, height: 6)
                        Text(VRConfig.baseURL?.absoluteString ?? "未设置服务器")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(VRTheme.textMute)
                            .lineLimit(1)
                    }
                    .padding(.top, 1)
                }
            }

            Text("长按桌面图标可添加到主屏幕，像 App 一样使用")
                .font(.system(size: 11.5))
                .foregroundColor(VRTheme.textMute)
                .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private var currentServerDotColor: Color {
        if case .connected = app.connection.status { return VRTheme.green }
        if case .connecting = app.connection.status { return VRTheme.gold }
        return VRTheme.textMute
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 13.5, weight: .bold))
            .foregroundColor(VRTheme.text)
    }
}

// MARK: - 房间人数标签（列表/卡片共用）

/// 人数徽标：有人时绿底「N 人」，空房灰底「空闲」
struct RoomCountTag: View {
    let count: Int

    var body: some View {
        Text(count > 0 ? "\(count) 人" : "空闲")
            .font(.system(size: 10.5, weight: .bold))
            .foregroundColor(count > 0 ? VRTheme.green : VRTheme.textMute)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(count > 0 ? VRTheme.green.opacity(0.16)
                                         : Color(hex: "27436B").opacity(0.08))
            )
    }
}
