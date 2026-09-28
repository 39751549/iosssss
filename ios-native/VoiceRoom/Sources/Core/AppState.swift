import Foundation
import SwiftUI
import Combine

/// 全局应用状态：登录态、当前房间、聊天、礼物、音乐
@MainActor
final class AppState: ObservableObject {

    // MARK: 登录与资料
    @Published var userId: String = ""
    @Published var me: VRUser?
    @Published var isLoggedIn: Bool = false

    // MARK: 大厅
    @Published var roomList: [VRRoomSummary] = []
    @Published var isLoadingRooms = false
    /// 我的永久房间（每人一个，无需重复创建）
    @Published var myRoom: VRMyRoom?

    // MARK: 当前房间
    @Published var roomState: VRRoomState?
    @Published var clientId: String = ""
    @Published var inRoom: Bool = false
    /// 房间最小化（悬浮球模式），不销毁房间状态
    @Published var roomMinimized: Bool = false
    @Published var messages: [VRChatMessage] = []
    @Published var giftList: [VRGift] = []
    @Published var giftAnimations: [GiftAnimation] = []

    // MARK: 语音
    @Published var micEnabled = false
    @Published var speakerEnabled = true
    @Published var speakingIds: Set<String> = []

    // MARK: 提示
    @Published var toast: ToastMessage?

    let connection = VRConnection()
    private let voice = VoiceEngine()
    private var cancellables = Set<AnyCancellable>()
    /// 最近所在房间（重连后自动回到房间）
    private var lastRoomId: String = ""

    /// 当前我是不是房主
    var isHost: Bool {
        guard let st = roomState else { return false }
        return st.hostClientId == clientId
    }

    var myMember: VRMember? {
        roomState?.member(clientId: clientId)
    }

    // MARK: - 生命周期

    init() {
        connection.onMessage = { [weak self] msg in
            self?.handle(msg)
        }
        // 语音引擎回调
        voice.onSpeakingChanged = { [weak self] ids in
            self?.speakingIds = ids
        }
        // 连接建立后自动登录（一键登录 / 断线重连恢复会话）
        connection.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] st in
                guard let self else { return }
                guard case .connected = st else { return }
                guard !self.userId.isEmpty else { return }
                self.silentAuth()
                // 重连后若之前在房间里，自动回到房间
                if self.inRoom, !self.lastRoomId.isEmpty {
                    self.connection.send(.roomJoin(userId: self.userId, roomId: self.lastRoomId, no: nil))
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - 登录

    func start() {
        loadIdentity()
        connection.connect()
    }

    private func loadIdentity() {
        let saved = UserDefaults.standard.string(forKey: "vr_userId")
        if let saved, !saved.isEmpty {
            userId = saved
            if let cached = LocalStore.loadUser() { me = cached }
        }
    }

    /// 登录（首次或更新资料）
    /// 账号名称登录：昵称即账号（同一昵称在任何设备上都是同一账号）
    func login(name: String, gender: Gender) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if userId.isEmpty {
            let clean = trimmed.lowercased()
                .replacingOccurrences(of: " ", with: "")
            userId = ("n" + clean).prefix(40).description
            UserDefaults.standard.set(userId, forKey: "vr_userId")
        }
        UserDefaults.standard.set(trimmed, forKey: "vr_name")
        connection.send(.auth(userId: userId, name: trimmed, avatar: nil, gender: gender, bio: nil))
    }

    /// 静默恢复登录（已有身份时）
    func silentAuth() {
        guard !userId.isEmpty else { return }
        connection.send(.auth(userId: userId, name: nil, avatar: nil, gender: nil, bio: nil))
    }

    // MARK: - 消息分发

    private func handle(_ msg: VRServerMessage) {
        switch msg {
        case let .authOK(uid, user, gifts):
            userId = uid
            me = user
            giftList = gifts
            isLoggedIn = true
            UserDefaults.standard.set(uid, forKey: "vr_userId")
            LocalStore.saveUser(user)
            requestRoomList()
            requestMyRoom()

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
            // 同账号在其他设备登录，本会话被顶下线
            showToast(reason, kind: .error)
            leaveRoom()

        case let .joinOK(cid, roomId, _):
            clientId = cid
            inRoom = true
            roomMinimized = false
            lastRoomId = roomId

        case let .joinFail(msg):
            showToast(msg, kind: .error)

        case let .roomState(st):
            let isFirst = (roomState == nil)
            roomState = st
            giftList = st.giftList
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
            }

        case let .gift(ev):
            pushGiftAnimation(ev)

        case let .coinsUpdate(coins, charm):
            me?.coins = coins
            me?.charm = charm
            if let u = me { LocalStore.saveUser(u) }

        case let .charmUpdate(user):
            // 更新房间里那个人的魅力值
            if var st = roomState,
               let idx = st.members.firstIndex(where: { $0.user.id == user.id }) {
                st.members[idx].user = user
                roomState = st
            }

        case let .error(msg):
            showToast(msg, kind: .error)

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
        connection.send(.roomJoin(userId: userId, roomId: id, no: nil))
    }

    func joinRoom(no: String) {
        connection.send(.roomJoin(userId: userId, roomId: nil, no: no))
    }

    func leaveRoom() {
        connection.send(.roomLeave)
        voice.stopAll()
        inRoom = false
        roomMinimized = false
        roomState = nil
        messages = []
        clientId = ""
        lastRoomId = ""
        micEnabled = false
        MusicPlayer.shared.stop()
    }

    // MARK: - 房间内操作

    func takeSeat(_ seat: Int) {
        connection.send(.seatChange(seat: seat))
        if seat >= 0 { enableMic() }
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
        voice.requestMic { [weak self] granted in
            guard let self else { return }
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

    func setRoomBackground(_ bg: RoomBackground) {
        guard let st = roomState else { return }
        connection.send(.roomBackground(roomId: st.room.id, background: bg.rawValue))
    }

    func updateProfile(name: String, gender: Gender, bio: String, avatar: String) {
        connection.send(.profileUpdate(userId: userId, name: name, avatar: avatar, gender: gender, bio: bio))
    }

    func activateVip(code: String) {
        connection.send(.vipLogin(userId: userId, code: code))
    }

    // MARK: - 音乐

    /// 加入歌单（曲库歌曲，按 libraryId）
    func addLibrarySong(libraryId: String, by: String) {
        connection.send(.musicAdd(title: "", url: "", by: by, libraryId: libraryId))
    }

    /// 加入歌单（外链）
    func addSongByURL(title: String, url: String) {
        connection.send(.musicAdd(title: title, url: url, by: me?.name ?? "未知", libraryId: nil))
    }

    /// 立即点播（全房间同步切歌）
    func playLibrarySong(libraryId: String, by: String) {
        connection.send(.musicPlayNow(libraryId: libraryId, by: by))
    }

    func musicControl(_ action: String, songId: String? = nil) {
        connection.send(.musicControl(action: action, songId: songId))
    }

    // MARK: - 礼物动画

    struct GiftAnimation: Identifiable, Equatable {
        let id: String
        let emoji: String
        let text: String
    }

    private func pushGiftAnimation(_ ev: VRGiftEvent) {
        let targetName = roomState?.members.first { $0.clientId == ev.toClientId }?.user.name ?? "房间"
        let anim = GiftAnimation(
            id: ev.id,
            emoji: ev.gift.emoji,
            text: "\(ev.from.name) 送出 \(ev.gift.name) ×\(ev.count)\n→ \(targetName)"
        )
        giftAnimations.append(anim)
        // 3.4 秒后自动移除
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) { [weak self] in
            self?.giftAnimations.removeAll { $0.id == anim.id }
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
