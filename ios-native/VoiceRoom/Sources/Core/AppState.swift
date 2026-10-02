import Foundation
import SwiftUI
import UIKit
import Combine

/// 全局应用状态：登录态、当前房间、聊天、礼物、音乐
@MainActor
final class AppState: ObservableObject {

    // MARK: 登录与资料
    @Published var userId: String = ""
    @Published var me: VRUser?
    @Published var isLoggedIn: Bool = false
    /// 已保存的登录凭据（登录成功后落盘，用于自动登录）
    private var savedUsername = ""
    private var savedPassword = ""
    /// 本次输入、等待服务端确认的凭据（连接晚于点登录时补发用）
    private var pendingUsername = ""
    private var pendingPassword = ""

    // MARK: 大厅
    @Published var roomList: [VRRoomSummary] = []
    @Published var isLoadingRooms = false
    /// 我的永久房间（每人一个，无需重复创建）
    @Published var myRoom: VRMyRoom?

    // MARK: 头像框（商城 / 背包）
    /// 商城在售的头像框（服务端 config.avatarFrames 下发）
    @Published var shopFrames: [VRAvatarFrame] = []
    /// 我已拥有的头像框 id（背包）
    @Published var ownedFrames: [String] = []
    /// 是否正在买 / 切换头像框（按钮转圈用）
    @Published var frameBusy = false
    /// 有没有成功拿到过商城清单。
    /// 光靠 `shopFrames.isEmpty` 判断"还在加载"是不行的 —— 拉失败了它也空，
    /// 界面就会永远转圈、还一声不吭（这正是"商城一直显示正在读取"的表现）。
    @Published var shopLoaded = false
    /// 这次拉取失败了（显示"加载失败，点这里重试"，而不是无限转圈）
    @Published var shopFailed = false
    /// 商城拉取的兜底定时器：5 秒还没收到回包就判失败
    private var shopTimeout: DispatchWorkItem?

    // MARK: 当前房间
    @Published var roomState: VRRoomState?
    @Published var clientId: String = ""
    @Published var inRoom: Bool = false
    /// 房间最小化（悬浮球模式），不销毁房间状态
    @Published var roomMinimized: Bool = false
    @Published var messages: [VRChatMessage] = []
    @Published var giftList: [VRGift] = []
    @Published var giftAnimations: [GiftAnimation] = []
    /// VIP 发言飘屏（VIP 在公屏说话时额外飘一条大字横幅）
    @Published var chatMarquees: [ChatMarquee] = []

    /// 当前房间的背景图（自定义图 / GIF）。
    ///
    /// 为什么放在 AppState 而不是让 RoomView 自己用 CachedAsyncImage 加载：
    /// RoomView 在「离开房间再进来」「切后台回来」时会被重建，视图内的 @State 图片
    /// 随之清空 —— 重新加载期间只能显示兜底渐变，用户看到的就是「背景变回默认了」，
    /// 而且每次都要等一遍磁盘/网络，表现为「设置了要等好久才生效」。
    /// 提到这里之后，整个 App 生命周期只加载一次，进出房间都是瞬时的。
    @Published var roomBackgroundImage: UIImage?
    private var roomBackgroundURL: URL?

    // MARK: 语音
    @Published var micEnabled = false
    @Published var speakerEnabled = true
    /// 「谁在说话」是**高频变化**的数据：有人开口/闭口就变一次，多人轮流聊天时每秒能变好几次。
    ///
    /// 它故意单独放在 `VoiceActivity` 里，不和 AppState 的其他状态混在一起：
    /// AppState 是个大对象，任何一个 `@Published` 变化都会让所有持有 `@EnvironmentObject var app`
    /// 的视图重新求值 —— 房间页、大厅、悬浮球全都得跟着重算一遍 body。
    /// 把说话状态摘出去之后，说话时只有真正订阅了它的麦位区/成员列表会重算。
    let activity = VoiceActivity()

    // MARK: 提示
    @Published var toast: ToastMessage?
    /// 被「另一台设备」顶下线（用于登录页说明原因 + 一键重登）
    @Published var kickedByOtherDevice = false

    /// 已保存的账号（登录页预填用，避免被顶后要重新回忆账号密码）
    var rememberedUsername: String { savedUsername }

    private var didStart = false

    let connection = VRConnection()
    private let voice = VoiceEngine()
    private var cancellables = Set<AnyCancellable>()
    /// 最近所在房间（重连后自动回到房间）
    private var lastRoomId: String = ""

    /// 当前我是不是房主
    var isHost: Bool {
        guard let st = roomState else { return false }
        // 优先用房间快照里的 ownerId 判断：它由服务端持久化，不会漂。
        // 之前只看 hostClientId，而 hostClientId 是按"0 号位坐的是谁"推出来的，
        // 一旦 0 号位出现残留记录就可能推错人 —— 房主会莫名其妙丢掉管理权限。
        if !st.room.ownerId.isEmpty { return st.room.ownerId == userId }
        return st.hostClientId == clientId
    }

    var myMember: VRMember? {
        roomState?.member(clientId: clientId)
    }

    /// 房主是不是 VIP —— 决定房间要不要走「金色闪光」氛围。
    /// 取的是房间快照里 ownerId 那个人的实时 VIP 状态，房主一升级全房立刻变金色。
    var isVipRoom: Bool {
        guard let st = roomState, !st.room.ownerId.isEmpty else { return false }
        return st.members.first { $0.user.id == st.room.ownerId }?.user.vip ?? false
    }

    /// 当前正在播放的歌是谁点的（userId）。麦位拿它点亮「点歌人」标识。
    var songRequesterId: String {
        guard let st = roomState, st.currentSong != nil else { return "" }
        return st.currentSong?.byUserId ?? ""
    }

    // MARK: - 生命周期

    init() {
        // 崩溃捕获要先于一切业务逻辑装好，才能兜住启动期的问题
        CrashReporter.install()
        connection.onMessage = { [weak self] msg in
            self?.handle(msg)
        }
        // 语音引擎回调
        voice.onSpeakingChanged = { [weak self] ids in
            self?.activity.speakingIds = ids
        }
        // 音乐播完 → 上报服务端按播放模式推进歌单
        MusicPlayer.shared.onPlaybackEnded = { [weak self] in
            self?.connection.send(.musicControl(action: "ended", songId: nil, mode: nil))
        }
        // 直链失效 → 请服务端重解析（修复"重进房间音乐放不了"）
        MusicPlayer.shared.onPlaybackFailed = { [weak self] in
            self?.connection.send(.musicControl(action: "reload", songId: nil, mode: nil))
        }
        // 连接建立后自动登录（有已保存/待确认凭据时；断线重连恢复会话）
        connection.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] st in
                guard let self else { return }
                guard case .connected = st else { return }
                // 链路就绪 → 用已保存的凭据静默登录。
                // 这就是「只要不卸载就永远不会掉线」的关键一步。
                self.silentAuth()
            }
            .store(in: &cancellables)
    }

    // MARK: - 登录

    func start() {
        // 幂等：SwiftUI 可能重复触发 onAppear，重复 connect 会在服务端留下两条同账号连接
        guard !didStart else { return }
        didStart = true

        savedUsername = UserDefaults.standard.string(forKey: "vr_username") ?? ""
        savedPassword = UserDefaults.standard.string(forKey: "vr_password") ?? ""
        // 恢复扬声器开关（默认开）
        if UserDefaults.standard.object(forKey: "vr_speaker") != nil {
            speakerEnabled = UserDefaults.standard.bool(forKey: "vr_speaker")
        }
        // 把恢复出来的开关同步给引擎，否则下次开麦时引擎会按自己的默认值（开外放）
        // 覆盖掉用户之前的选择，UI 显示"已关"而实际是外放
        voice.setSpeakerEnabled(speakerEnabled)
        if let cached = LocalStore.loadUser() { me = cached }
        connection.connect()
    }

    /// App 进入后台时调用。
    /// 不在房间里就彻底释放音频会话 —— 否则「打开过 App」这件事本身会让系统
    /// 认为麦克风/扬声器仍被占用（那是上一版在 init 里激活会话留下的坑）。
    /// 在房间里则保留会话，这样切后台/锁屏能继续听歌、继续语音。
    func appDidEnterBackground() {
        guard !inRoom else { return }
        voice.stopAll()
    }

    /// App 回到前台时调用。
    /// 切后台期间系统可能已经掐掉 WebSocket（进程被挂起，收不到失败回调），
    /// 回前台后不主动探测就会一直停在"正在连接"。这里直接发起一次重连，
    /// 连上后由 status 回调自动静默登录。
    func appDidBecomeActive() {
        guard isLoggedIn || !savedUsername.isEmpty || !pendingUsername.isEmpty else { return }
        if connection.isConnected {
            // 链路还在，但登录态丢了（例如刚被顶下线过）→ 补一次静默登录
            if !isLoggedIn { silentAuth() }
            // 切后台期间房间可能已经变了（有人进出、背景被改）→ 回前台拉一次最新快照。
            // 以前要退出房间重进才能看到变化。
            requestRoomSync()
        } else {
            connection.reconnectNow()
        }
    }

    /// 登录（账号密码；新账号服务端自动注册）
    func login(username: String, password: String) {
        let clean = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        pendingUsername = clean
        pendingPassword = password
        kickedByOtherDevice = false
        // 显式登录：先把链路准备好。
        // 被顶下线 / 主动登出之后 shouldReconnect 是 false、task 是 nil，
        // 不先 resume 的话下面的 send 会被静默丢弃，表现为"点了登录没反应"。
        connection.resume()
        connection.send(.auth(username: clean, password: password))
    }

    /// 静默登录：优先用刚输入待确认的凭据，其次已保存凭据
    func silentAuth() {
        let u = !pendingUsername.isEmpty ? pendingUsername : savedUsername
        let p = !pendingPassword.isEmpty ? pendingPassword : savedPassword
        guard !u.isEmpty, !p.isEmpty else { return }
        connection.send(.auth(username: u, password: p))
    }

    /// 退出登录：清凭据并断开（回到登录页）
    func logout() {
        savedUsername = ""
        savedPassword = ""
        pendingUsername = ""
        pendingPassword = ""
        UserDefaults.standard.removeObject(forKey: "vr_username")
        UserDefaults.standard.removeObject(forKey: "vr_password")
        UserDefaults.standard.removeObject(forKey: "vr_userId")
        isLoggedIn = false
        userId = ""
        leaveRoom()
        connection.disconnect()
    }

    // MARK: - 消息分发

    private func handle(_ msg: VRServerMessage) {
        switch msg {
        case let .authOK(uid, user, gifts):
            userId = uid
            me = user
            giftList = gifts
            isLoggedIn = true
            kickedByOtherDevice = false
            // 登录成功：凭据落盘，下次自动登录
            if !pendingUsername.isEmpty {
                savedUsername = pendingUsername
                savedPassword = pendingPassword
                pendingUsername = ""
                pendingPassword = ""
                UserDefaults.standard.set(savedUsername, forKey: "vr_username")
                UserDefaults.standard.set(savedPassword, forKey: "vr_password")
            }
            UserDefaults.standard.set(uid, forKey: "vr_userId")
            LocalStore.saveUser(user)
            requestRoomList()
            requestMyRoom()
            // 登录后顺手把 5 张内置背景拉进本地缓存：只按 .thumb 解码（内存很省），
            // 主要目的是把文件落进磁盘缓存 —— 之后进房间、打开背景选择器都是本地读取，
            // 不会再有"设了背景要等半天才出来"的观感。
            warmUpPresetBackgrounds()
            // 断线重连后自动回到原来所在的房间。
            // 放在 authOK 里而不是 status 回调里：这样能保证服务端已认得这个身份，
            // 也保证 join 一定排在 auth 之后（顺序有保证，不用赌时序）。
            if inRoom, !lastRoomId.isEmpty {
                connection.send(.roomJoin(userId: uid, roomId: lastRoomId, no: nil))
            }
            // 登录成功 = 链路可用 → 把上次崩溃的现场报给服务端（有则取走并清掉本地文件）。
            // 就算没有异常记录，面包屑也能说明上次会话死在哪一步（如 watchdog 强杀）。
            let crashPart = CrashReporter.consumeReport()
            let crumbPart = CrashReporter.tailCrumbs()
            if crashPart != nil || crumbPart != nil {
                var report = ""
                if let crashPart { report += crashPart + "\n" }
                if let crumbPart { report += "--- last actions ---\n" + crumbPart }
                connection.send(.crashReport(log: String(report.prefix(8000))))
                CrashReporter.clearCrumbs()
            }

        case let .profileOK(user):
            me = user
            LocalStore.saveUser(user)
            showToast("名片已更新", kind: .success)

        case let .vipOK(user):
            me = user
            LocalStore.saveUser(user)
            showToast("🎉 VIP 激活成功，获得 5000 金币", kind: .success)

        case let .vipFail(msg):
            showToast(msg, kind: .error)

        case let .roomCreated(id, _, _):
            connection.send(.roomJoin(userId: userId, roomId: id, no: nil))

        case let .roomList(list):
            roomList = list
            isLoadingRooms = false

        case .roomsChanged:
            // 别人的大厅列表变了（建房 / 解散 / 改名 / 换头像）。
            // 在房间里时不用管 —— 房间自己的数据走 room:state，大厅列表等回去再拉。
            if !inRoom { requestRoomList() }

        case let .shopList(frames, owned, wearing, coins):
            shopFrames = frames
            ownedFrames = owned
            frameBusy = false
            shopLoaded = true
            shopFailed = false
            shopTimeout?.cancel()
            VRFrameCatalog.shared.setFrames(frames)
            // 服务端才是背包/穿戴的权威，顺手把本地资料对齐
            if me?.frame != wearing { me?.frame = wearing }
            if let c = me?.coins, c != coins { me?.coins = coins }

        case let .shopOwned(owned, wearing, coins, frame):
            ownedFrames = owned
            frameBusy = false
            if let f = frame {
                // 服务端回传的最新资料：金币已扣、头像框已穿
                me = f
                // 房间里自己那条成员记录也要跟着变，不然头像框要等下次快照才生效
                if var st = roomState, let idx = st.members.firstIndex(where: { $0.user.id == f.id }) {
                    st.members[idx].user = f
                    roomState = st
                }
            } else {
                me?.frame = wearing
                me?.coins = coins
            }

        case let .roomMy(room):
            myRoom = room

        case let .roomDestroyed(roomId):
            myRoom = nil
            if roomState?.room.id == roomId { leaveRoom() }
            showToast("房间已解散", kind: .success)

        case let .roomClosed(reason):
            // 房主解散了房间，所有人退出
            if inRoom {
                showToast(reason, kind: .error)
                leaveRoom()
            }

        case let .roomKicked(reason):
            // 同账号在「另一台设备」登录，本会话被顶下线。
            // 这里只停掉当前会话、不再自动重连（两边都自动重连会互相抢号，形成死循环）。
            // 但**保留**已保存的账号密码：以前连凭据一起清掉，于是一次判定失误就得让用户
            // 重新输密码；现在登录页会预填，点一下就能回到岛上。
            // 注：本机切后台重连不会再走到这里——服务端已用 deviceId 把「本机重连」识别为静默替换。
            kickedByOtherDevice = true
            showToast(reason, kind: .error)
            leaveRoom()
            isLoggedIn = false
            userId = ""
            connection.disconnect()

        case let .joinOK(cid, roomId, _):
            clientId = cid
            inRoom = true
            roomMinimized = false
            lastRoomId = roomId
            // 进房只需"听到别人"：开播放通道即可，先不碰麦克风。
            // 等用户真的开麦（点麦位）再切到双向语音，避免一进房就亮麦克风提示。
            voice.enterListenMode()

        case let .joinFail(msg):
            showToast(msg, kind: .error)

        case let .roomState(raw):
            let st = sanitize(raw)
            let isFirst = (roomState == nil)
            roomState = st
            giftList = st.giftList
            // 背景图在 AppState 层维护：URL 没变就复用，变了才重新加载
            refreshRoomBackground()
            if isFirst {
                messages = st.chatLog
                // 进房后与已在房的人建立语音连接
                voice.connectToExistingPeers(st.members.filter { $0.clientId != clientId }.map(\.clientId))
            }
            // 同步音乐播放状态
            MusicPlayer.shared.sync(with: st, speakerOn: speakerEnabled)

        case let .peerNew(cid, _):
            // 有人进来：我（老成员）主动发起 offer
            voice.createOffer(to: cid)

        case let .peerBye(cid):
            voice.closePeer(cid)

        case let .chat(m):
            // 去重（重连后会重放历史）
            if !messages.contains(where: { $0.id == m.id }) {
                messages.append(m)
                if messages.count > 200 { messages.removeFirst(messages.count - 200) }
                // VIP 发言额外飘一条横幅（普通用户不飘，否则公屏一热就满天飞）
                if m.vip == true && !m.isSystem { pushChatMarquee(m) }
            }

        case let .gift(ev):
            pushGiftAnimation(ev)

        case let .coinsUpdate(coins, charm):
            me?.coins = coins
            me?.charm = charm
            if let u = me { LocalStore.saveUser(u) }

        case let .charmUpdate(users):
            // 服务端把「本次送礼导致变动的所有人」合并成一条消息推过来
            // （送礼人 + 每个收礼人）。这里一次性就地替换这些成员，
            // 而不是收一份完整快照 —— 收礼的人越多，省下的序列化/下发越多。
            if var st = roomState, !users.isEmpty {
                var hit = false
                for u in users {
                    if let idx = st.members.firstIndex(where: { $0.user.id == u.id }) {
                        st.members[idx].user = u
                        hit = true
                    }
                }
                // 顺带刷新自己的资料：送礼也会涨自己的魅力值
                if let mine = users.first(where: { $0.id == me?.id }) {
                    me?.coins = mine.coins
                    me?.charm = mine.charm
                    // 服务端已经算好 VIP 等级，直接同步，省一次全量刷新
                    me?.vip = mine.vip
                    me?.vipLevel = mine.vipLevel
                    if let m = me { LocalStore.saveUser(m) }
                }
                if hit { roomState = st }
            }

        case let .roomNoOK(no):
            showToast("房间号已改为 \(no)", kind: .success)

        case let .rtcOffer(from, sdp):
            voice.handleOffer(from: from, sdp: sdp)

        case let .rtcAnswer(from, sdp):
            voice.handleAnswer(from: from, sdp: sdp)

        case let .rtcIce(from, candidate):
            voice.handleIce(from: from, candidate: candidate)

        case let .rtcBye(from):
            voice.closePeer(from)

        case let .error(msg):
            showToast(msg, kind: .error)
            // 买框 / 换框失败时要把按钮解锁，否则会一直转圈
            frameBusy = false
            // 商城还没成功加载过就报错 → 标记失败。
            // 不然 ShopSheet 分不清"还在加载"和"已经失败了"，会永远停在"正在读取头像框…"。
            if !shopLoaded { shopFailed = true }

        case .unknown:
            break
        }
    }

    // MARK: - 大厅操作

    func requestRoomList() {
        isLoadingRooms = true
        connection.send(.roomList)
    }

    func requestMyRoom() {
        guard !userId.isEmpty else { return }
        connection.send(.roomMy(userId: userId))
    }

    // MARK: - 头像框（商城 / 背包）

    /// 拉商城清单 + 我的背包 + 当前穿戴 + 金币余额（商城页 / 背包页打开时调）
    ///
    /// 带 5 秒兜底：万一这条消息丢了 / 服务端换了协议没回包，
    /// 也要让界面显示"加载失败"而不是无限转圈 —— 用户至少知道该重试。
    func requestShop() {
        shopFailed = false
        connection.send(.shopList)
        shopTimeout?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self, !self.shopLoaded else { return }
            self.shopFailed = true
        }
        shopTimeout = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
    }

    /// 用金币买头像框：服务端校验余额并扣钱，买完自动戴上（买框就是为了戴）
    func buyFrame(_ id: String) {
        guard !frameBusy else { return }
        frameBusy = true
        connection.send(.shopBuy(frameId: id))
    }

    /// 穿戴 / 脱下头像框（传 nil 或空串 = 脱下）
    func wearFrame(_ id: String?) {
        guard !frameBusy else { return }
        frameBusy = true
        connection.send(.frameWear(frameId: id ?? ""))
    }

    /// 这个头像框我有没有（默认框人人都有）
    func ownsFrame(_ id: String) -> Bool {
        if shopFrames.first(where: { $0.id == id })?.price == 0 { return true }
        return ownedFrames.contains(id)
    }

    /// 房主解散自己的永久房间（房间内 / 大厅均可调用）
    func destroyMyRoom(_ roomId: String? = nil) {
        let rid = roomId ?? roomState?.room.id ?? myRoom?.id ?? ""
        guard !rid.isEmpty else { return }
        connection.send(.roomDestroy(userId: userId, roomId: rid))
    }

    func createRoom(name: String, background: RoomBackground) {
        connection.send(.roomCreate(userId: userId, name: name, background: background.rawValue))
    }

    func joinRoom(id: String) {
        // 要进的就是**当前已经待着的房间** → 只把最小化的房间展开，不发 room:join。
        //
        // 为什么必须挡住这一次 join：服务端收到 room:join 会走一整套进房流程 ——
        // 摘掉本连接的旧身份、重新分配麦位、给所有老成员广播 peer:new（于是每个人都要
        // 重建一次 WebRTC 连接）、重推全量快照、再往公屏刷一条"XX 进入了房间"。
        // 用户只是从悬浮球点回自己的房间，看到的却是整间房刷新了一遍 +
        // 公屏多出一条进房消息 —— 就是"点进入房间就重新进了一次"。
        if inRoom, roomState?.room.id == id || lastRoomId == id {
            resumeCurrentRoom()
            return
        }
        leaveIfSwitching(to: id)
        connection.send(.roomJoin(userId: userId, roomId: id, no: nil))
    }

    func joinRoom(no: String) {
        // 同上：输入的就是当前房间号 → 直接展开，不重新进房
        if inRoom, roomState?.room.no == no {
            resumeCurrentRoom()
            return
        }
        // 用房间号进房比不了 id，只要在房间里就先退（退完再进，语义正确且不会留下幽灵）
        if inRoom { leaveRoom() }
        connection.send(.roomJoin(userId: userId, roomId: nil, no: no))
    }

    /// 展开最小化的房间（从悬浮球 / 大厅点"进入我的房间"回到房间里）。
    ///
    /// 只做两件事：取消最小化 + 拉一次最新快照。
    /// `requestRoomSync` 是纯读操作 —— 只回给请求方一份 room:state，不会重连语音、
    /// 不会动麦位、不会刷公屏，所以既能对齐"我离开这段时间有人进出了"，
    /// 又不会让用户感觉到"重新进了一次房间"。
    func resumeCurrentRoom() {
        roomMinimized = false
        requestRoomSync()
    }

    /// 换房前先退掉当前房间。
    ///
    /// 以前是直接 join，旧的成员记录会留在原房间变成"幽灵"：同一个人出现两条记录
    /// （界面上就是"房间里有两个我"），而且服务端会把 peer:new 发给这条连接自己。
    /// 服务端现在也会兜底清理，但客户端先退房才是正确的时序：原房间能收到"离开了房间"，
    /// 麦位也能及时腾出来。
    private func leaveIfSwitching(to roomId: String) {
        guard inRoom, roomState?.room.id != roomId else { return }
        leaveRoom()
    }

    func leaveRoom() {
        connection.send(.roomLeave)
        voice.stopAll()
        inRoom = false
        roomMinimized = false
        roomState = nil
        messages = []
        giftAnimations = []
        chatMarquees = []
        comboToken = [:]
        activity.speakingIds = []
        clientId = ""
        lastRoomId = ""
        micEnabled = false
        // 背景图故意**不**清空：马上又回同一个房间时可以直接复用，
        // 不用等重新加载（那一小段空窗就是用户看到的"背景变回默认了"）。
        // 真的换了房间时，refreshRoomBackground() 会按新的背景路径自动换掉/清掉它。
        MusicPlayer.shared.stop()
    }

    // MARK: - 房间内操作

    func takeSeat(_ seat: Int) {
        CrashReporter.crumb("app: takeSeat \(seat)")
        connection.send(.seatChange(seat: seat))
        if seat >= 0 { enableMic() }
        // 换麦序顺手拉一次快照：座位变了房间状态就该立刻刷新
        // （房间背景这类"看起来没生效"的东西也一起跟着刷新，不用退出重进）
        requestRoomSync()
    }

    /// 主动向服务端要一次最新的房间快照。
    /// 什么时候用：设置房间背景 / 换麦位 / 回前台 / 关掉设置面板之后 ——
    /// 这些场景以前只能靠"退出房间再进来"触发一次完整快照。
    func requestRoomSync() {
        guard inRoom, !lastRoomId.isEmpty else { return }
        connection.send(.roomSync)
    }

    // MARK: - 房间快照清洗

    /// 同一账号只保留一条成员记录，并按结果重建麦位表。
    ///
    /// 残留连接（换房不先退房、断线后又一次 join）会让同一个人出现两条成员记录，
    /// 界面上就是「房间里有两个我」：人数 +1、麦位被自己占两个，
    /// 点麦位还会因为两条记录来回切而反复弹名片。
    /// 服务端已经会摘掉这类幽灵，这里再做一层兜底，保证界面永远只看到一个我。
    private func sanitize(_ st: VRRoomState) -> VRRoomState {
        var s = st
        // 优先保留"我自己的 clientId"那条，其次保留加入时间最新的
        var best: [String: VRMember] = [:]
        var order: [String] = []
        for m in st.members {
            let key = m.user.id.isEmpty ? m.clientId : m.user.id
            guard let cur = best[key] else {
                best[key] = m; order.append(key); continue
            }
            if m.clientId == clientId, cur.clientId != clientId {
                best[key] = m
            } else if cur.clientId != clientId, m.joinedAt > cur.joinedAt {
                best[key] = m
            }
        }
        s.members = order.compactMap { best[$0] }
        // seats 表也照清洗后的成员重建，避免指向已经不存在的 clientId
        let seatCount = max(9, s.seats.count)
        var seats = [String?](repeating: nil, count: seatCount)
        for m in s.members where m.seat >= 0 && m.seat < seatCount { seats[m.seat] = m.clientId }
        s.seats = seats
        return s
    }

    func toggleMic() {
        if !micEnabled {
            enableMic()
        } else {
            micEnabled = false
            voice.setMicEnabled(false)
            connection.send(.micToggle(muted: true))
        }
    }

    private func enableMic() {
        CrashReporter.crumb("app: enableMic enter (micEnabled=\(micEnabled))")
        voice.requestMic { [weak self] granted in
            guard let self else { return }
            CrashReporter.crumb("app: requestMic callback granted=\(granted)")
            if granted {
                self.micEnabled = true
                self.voice.setMicEnabled(true)
                self.connection.send(.micToggle(muted: false))
                self.showToast("麦克风已开启 🎤", kind: .success)
            } else {
                self.micEnabled = false
                self.showToast("无法访问麦克风，请在设置中允许", kind: .error)
            }
        }
    }

    func toggleSpeaker() {
        speakerEnabled.toggle()
        voice.setSpeakerEnabled(speakerEnabled)
        MusicPlayer.shared.setMuted(!speakerEnabled)
        UserDefaults.standard.set(speakerEnabled, forKey: "vr_speaker")
        showToast(speakerEnabled ? "扬声器已开" : "扬声器已关")
    }

    func sendChat(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        connection.send(.chat(userId: userId, text: t))
    }

    func sendGift(giftId: String, count: Int, toClientId: String) {
        connection.send(.giftSend(userId: userId, giftId: giftId, count: count, toClientId: toClientId))
    }

    func renameRoom(_ name: String) {
        guard let st = roomState else { return }
        connection.send(.roomRename(roomId: st.room.id, userId: userId, name: name))
    }

    /// VIP 自定义房间号（永久保存）
    func setRoomNo(_ no: String) {
        guard let st = roomState else { return }
        connection.send(.roomSetNo(roomId: st.room.id, userId: userId, no: no))
    }

    func setRoomBackground(_ bg: RoomBackground) {
        guard let st = roomState else { return }
        connection.send(.roomBackground(roomId: st.room.id, background: bg.rawValue))
        // 乐观更新：本地先把房间状态改掉，再自己去加载这张图，
        // 不等服务端快照回包 —— 否则用户点完要盯着旧背景等，体感就是"点了没反应"。
        // 同步改 roomState.background 还有个副作用是好的：渐变兜底层是照它画的，
        // 只换图片不改这里的话，画面要等下一次快照才变（表现为"必须退出重进才生效"）。
        roomState?.room.background = bg.rawValue
        refreshRoomBackground()
        // 再拉一次快照兜底，保证和其他端一致
        requestRoomSync()
    }

    // MARK: - 房间背景图

    /// 预热 5 张内置背景（只解第一帧，内存开销极小；目的是喂饱磁盘缓存）
    func warmUpPresetBackgrounds() {
        for bg in RoomBackground.presets {
            guard let url = VRConfig.absoluteURL(for: bg.id) else { continue }
            MediaCache.shared.prefetch(url, profile: .thumb)
        }
    }

    /// 依据当前房间快照刷新背景图（URL 没变就直接复用，不重新解码）
    ///
    /// 内置 5 张背景也是「路径」（/presets/preset-N.gif），走的就是这条通用逻辑，
    /// 不需要给内置/自定义分两套代码 —— 自定义背景的行为因此完全没变。
    private func refreshRoomBackground() {
        let path = roomState?.effectiveBackground ?? ""
        guard let url = VRConfig.absoluteURL(for: path) else {
            // 老主题名（aurora/hearts）或空值：没有图，交给兜底渐变
            roomBackgroundURL = nil
            roomBackgroundImage = nil
            return
        }
        if roomBackgroundURL == url, roomBackgroundImage != nil { return }
        loadRoomBackground(url)
    }

    private func loadRoomBackground(_ url: URL) {
        // 换的是另一张图 → 先撤掉旧图，别在房间里看到上一个房间的背景
        if roomBackgroundURL != url { roomBackgroundImage = nil }
        roomBackgroundURL = url
        // 内存命中 → 同步拿到，一帧都不会闪
        if let hit = MediaCache.shared.cachedImage(for: url, profile: .background) {
            roomBackgroundImage = hit
            return
        }
        // 内存没有 → 走磁盘缓存（快），仍没有才下载。
        // 按 background 档位解码：服务端上的背景 GIF 常有 4MB、50 帧，
        // 按原尺寸全帧解码一张就是 40MB+，会直接触发内存警告把缓存清空。
        MediaCache.shared.image(for: url, profile: .background) { [weak self] img in
            guard let self, self.roomBackgroundURL == url else { return }
            self.roomBackgroundImage = img
        }
    }

    /// 上传成功时立刻应用（本机已经有这张图了，不必等服务端快照、也不必再下一次）
    func applyRoomBackground(path: String, image: UIImage?) {
        guard let url = VRConfig.absoluteURL(for: path) else { return }
        roomBackgroundURL = url
        // 房间状态一并改掉：这样紧接着到达的快照就算不含这个字段，
        // 界面也已经是对的（以前要退出重进才看到）
        roomState?.room.background = path
        if let image {
            roomBackgroundImage = image
        } else {
            loadRoomBackground(url)
        }
    }

    func updateProfile(name: String, gender: Gender, bio: String, avatar: String) {
        connection.send(.profileUpdate(userId: userId, name: name, avatar: avatar, gender: gender, bio: bio))
    }

    func activateVip(code: String) {
        connection.send(.vipLogin(userId: userId, code: code))
    }

    // MARK: - 音乐

    /// 加入歌单（曲库歌曲，按 libraryId；在线歌曲带上歌名方便歌单展示）
    func addLibrarySong(libraryId: String, title: String = "", artist: String = "", by: String) {
        connection.send(.musicAdd(title: title, artist: artist, url: "", by: by, libraryId: libraryId))
    }

    /// 加入歌单（外链）
    func addSongByURL(title: String, url: String) {
        connection.send(.musicAdd(title: title, artist: "", url: url, by: me?.name ?? "未知", libraryId: nil))
    }

    /// 立即点播（全房间同步切歌；在线歌曲由服务器实时解析直链）
    func playLibrarySong(libraryId: String, by: String, title: String? = nil, artist: String? = nil) {
        connection.send(.musicPlayNow(libraryId: libraryId, by: by, title: title, artist: artist))
    }

    func musicControl(_ action: String, songId: String? = nil, mode: String? = nil) {
        connection.send(.musicControl(action: action, songId: songId, mode: mode))
    }

    /// 切换播放模式（列表循环 → 单曲循环 → 播完结束）
    func cyclePlayMode() {
        guard let cur = roomState else { return }
        let next = cur.mode.next
        connection.send(.musicControl(action: "mode", songId: nil, mode: next.rawValue))
        showToast("\(next.icon) \(next.label)", kind: .success)
    }

    // MARK: - 礼物 / 发言飘屏

    /// 礼物飘屏分三档（按礼物单价），档位越高特效越"大"：
    /// - `.small` 小礼物 → 右侧飘屏
    /// - `.mid`   中档   → 底部横幅 + 头像飞入
    /// - `.big`   大礼物 → 全屏爆炸 + 底部横幅
    enum GiftTier: Int, Equatable { case small = 1, mid = 2, big = 3 }

    struct GiftAnimation: Identifiable, Equatable {
        let id: String
        /// 连击归并键：同一送礼人 → 同一收礼人 → 同一礼物
        let comboKey: String
        let fromName: String
        let fromAvatar: String
        let toName: String
        let emoji: String
        let giftName: String
        /// 连击数量（这一条上已经累加了几份）
        var count: Int
        let tier: GiftTier
    }

    /// VIP 发言飘屏
    struct ChatMarquee: Identifiable, Equatable {
        let id: String
        let name: String
        let avatar: String
        let text: String
        let vipLevel: Int
    }

    /// 每条飘屏的「续期令牌」：连击时换发新令牌，4 秒后到点的旧令牌会被丢弃。
    /// 这样既不需要维护定时器，连击过程中飘屏也不会中途消失。
    private var comboToken: [String: UUID] = [:]

    /// 一次「送出礼物」事件 → 飘屏。
    ///
    /// 连击归并：同一个人对同一个人连送同一种礼物，只累加数量、不新增条目 ——
    /// 连点 20 次只占一条（显示 ×20），既好看也不会把屏幕糊满，
    /// 顺带把动画数量从"每次一份"压到"最多 3 份同时跑"。
    private func pushGiftAnimation(_ ev: VRGiftEvent) {
        let price = giftList.first { $0.id == ev.gift.id }?.price ?? 0
        let tier: GiftTier = price >= 10000 ? .big : (price >= 1000 ? .mid : .small)
        let key = "\(ev.from.id)|\(ev.toClientId ?? "")|\(ev.gift.id)"
        let toName = roomState?.members.first { $0.clientId == ev.toClientId }?.user.name ?? "全房间"

        if let idx = giftAnimations.firstIndex(where: { $0.comboKey == key }) {
            giftAnimations[idx].count += ev.count
            armGiftRemoval(giftAnimations[idx].id)
            return
        }

        let anim = GiftAnimation(id: ev.id, comboKey: key,
                                 fromName: ev.from.name, fromAvatar: ev.from.avatar,
                                 toName: toName, emoji: ev.gift.emoji,
                                 giftName: ev.gift.name, count: ev.count, tier: tier)
        giftAnimations.append(anim)
        // 同时最多 3 条：超出的顶掉最旧的
        if giftAnimations.count > 3 {
            let dropped = Array(giftAnimations.prefix(giftAnimations.count - 3)).map(\.id)
            giftAnimations.removeFirst(giftAnimations.count - 3)
            for d in dropped { comboToken[d] = nil }
        }
        armGiftRemoval(anim.id)
    }

    private func armGiftRemoval(_ id: String) {
        let token = UUID()
        comboToken[id] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) { [weak self] in
            guard let self, self.comboToken[id] == token else { return }
            self.comboToken[id] = nil
            self.giftAnimations.removeAll { $0.id == id }
        }
    }

    /// VIP 在公屏说话 → 飘一条大字横幅。
    ///
    /// 只认「刚发生」的消息：断线重连会整段重放历史公屏，
    /// 不按时间过滤的话，一进房间就会飘出好几条早就说过的 VIP 消息。
    private func pushChatMarquee(_ m: VRChatMessage) {
        guard Date().timeIntervalSince1970 * 1000 - m.at < 15_000 else { return }
        guard !chatMarquees.contains(where: { $0.id == m.id }) else { return }
        chatMarquees.append(ChatMarquee(id: m.id,
                                        name: m.name ?? "?",
                                        avatar: m.avatar ?? "",
                                        text: m.text,
                                        vipLevel: m.vipLevel ?? 1))
        if chatMarquees.count > 2 { chatMarquees.removeFirst(chatMarquees.count - 2) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
            self?.chatMarquees.removeAll { $0.id == m.id }
        }
    }

    // MARK: - Toast

    struct ToastMessage: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let kind: Kind
        enum Kind { case info, success, error }
    }

    func showToast(_ text: String, kind: ToastMessage.Kind = .info) {
        let t = ToastMessage(text: text, kind: kind)
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            if self?.toast?.id == t.id { self?.toast = nil }
        }
    }
}

// MARK: - 说话状态（高频，单独成对象）

/// 「谁在说话」。
///
/// 单独拿出来是因为它更新得**非常频繁**（WebRTC 每 0.35 秒探一次音量，
/// 有人开口或闭嘴就推一次；多人轮流聊天时每秒好几次）。
/// 如果它挂在 AppState 上，每次说话变化都会让所有持有 AppState 的视图重算 body ——
/// 房间页要重算 9 个麦位 + 公屏 + 悬浮条，代价远大于"给两个头像加个绿圈"本身。
/// 摘出来之后，只有真正订阅它的视图（麦位区、成员列表、悬浮球）会跟着刷新。
@MainActor
final class VoiceActivity: ObservableObject {
    @Published var speakingIds: Set<String> = []
}

// MARK: - 本地持久化

enum LocalStore {
    private static let userKey = "vr_cached_user"

    static func saveUser(_ u: VRUser) {
        guard let data = try? JSONEncoder().encode(u) else { return }
        UserDefaults.standard.set(data, forKey: userKey)
    }

    static func loadUser() -> VRUser? {
        guard let data = UserDefaults.standard.data(forKey: userKey) else { return nil }
        return try? JSONDecoder().decode(VRUser.self, from: data)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: userKey)
    }
}
