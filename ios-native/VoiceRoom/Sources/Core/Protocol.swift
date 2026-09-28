import Foundation

// MARK: - 服务端地址配置
//
// 部署后把这里改成你的真实地址。也可以在 App 内「设置」里改（会覆盖此默认值）。
enum VRConfig {
    /// 默认服务器地址（不含协议）
    /// 已经部署在腾讯云：HTTP 直连 IP + 端口
    /// 换服务器时改这里，或直接在 App 内「设置」里改（会覆盖此默认值）
    static let defaultHost = "43.142.76.172:8125"

    /// 是否使用 https/wss。当前服务器是 http 直连，设为 false
    static let useTLS = false

    static var baseURL: URL? {
        guard let host = ServerStore.shared.host else { return nil }
        let scheme = ServerStore.shared.useTLS ? "https" : "http"
        return URL(string: "\(scheme)://\(host)")
    }

    static var wsURL: URL? {
        guard let host = ServerStore.shared.host else { return nil }
        let scheme = ServerStore.shared.useTLS ? "wss" : "ws"
        return URL(string: "\(scheme)://\(host)")
    }
}

/// 服务器地址的本地存储（App 内可改，无需重新打包）
final class ServerStore: ObservableObject {
    static let shared = ServerStore()

    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "vr_host") }
    }
    @Published var useTLS: Bool {
        didSet { UserDefaults.standard.set(useTLS, forKey: "vr_tls") }
    }

    private init() {
        let savedHost = UserDefaults.standard.string(forKey: "vr_host")
        self.host = (savedHost?.isEmpty == false) ? savedHost! : VRConfig.defaultHost
        if UserDefaults.standard.object(forKey: "vr_tls") == nil {
            self.useTLS = VRConfig.useTLS
        } else {
            self.useTLS = UserDefaults.standard.bool(forKey: "vr_tls")
        }
    }
}

// MARK: - 消息协议（与服务端 server.js 严格对应）

enum VRClientMessage {
    case auth(userId: String, name: String?, avatar: String?, gender: Gender?, bio: String?)
    case profileUpdate(userId: String, name: String?, avatar: String?, gender: Gender?, bio: String?)
    case vipLogin(userId: String, code: String)
    case roomCreate(userId: String, name: String, background: String)
    case roomList
    /// 查询我的永久房间
    case roomMy(userId: String)
    /// 房主解散自己的永久房间
    case roomDestroy(userId: String, roomId: String)
    case roomJoin(userId: String, roomId: String?, no: String?)
    case roomLeave
    case roomRename(roomId: String, userId: String, name: String)
    case roomBackground(roomId: String, background: String)
    case seatChange(seat: Int)
    case micToggle(muted: Bool)
    case chat(userId: String, text: String)
    case giftSend(userId: String, giftId: String, count: Int, toClientId: String)
    /// 加入歌单：libraryId 优先（曲库点播），否则用 url + title（外链）
    case musicAdd(title: String, artist: String, url: String, by: String, libraryId: String?)
    /// 立即点播：替换当前歌曲
    case musicPlayNow(libraryId: String, by: String, title: String?, artist: String?)
    case musicControl(action: String, songId: String?)
    // WebRTC 信令
    case rtcOffer(to: String, sdp: String)
    case rtcAnswer(to: String, sdp: String)
    case rtcIce(to: String, candidate: [String: Any])
    case rtcBye(to: String)

    var payload: [String: Any] {
        switch self {
        case let .auth(userId, name, avatar, gender, bio):
            var profile: [String: Any] = [:]
            if let name { profile["name"] = name }
            if let avatar { profile["avatar"] = avatar }
            if let gender { profile["gender"] = gender.rawValue }
            if let bio { profile["bio"] = bio }
            return ["type": "auth", "userId": userId, "profile": profile]

        case let .profileUpdate(userId, name, avatar, gender, bio):
            var patch: [String: Any] = [:]
            if let name { patch["name"] = name }
            if let avatar { patch["avatar"] = avatar }
            if let gender { patch["gender"] = gender.rawValue }
            if let bio { patch["bio"] = bio }
            return ["type": "profile:update", "userId": userId, "patch": patch]

        case let .vipLogin(userId, code):
            return ["type": "vip:login", "userId": userId, "code": code]

        case let .roomCreate(userId, name, background):
            return ["type": "room:create", "userId": userId, "name": name, "background": background]

        case .roomList:
            return ["type": "room:list"]

        case let .roomMy(userId):
            return ["type": "room:my", "userId": userId]

        case let .roomDestroy(userId, roomId):
            return ["type": "room:destroy", "userId": userId, "roomId": roomId]

        case let .roomJoin(userId, roomId, no):
            var p: [String: Any] = ["type": "room:join", "userId": userId]
            if let roomId { p["roomId"] = roomId }
            if let no { p["no"] = no }
            return p

        case .roomLeave:
            return ["type": "room:leave"]

        case let .roomRename(roomId, userId, name):
            return ["type": "room:rename", "roomId": roomId, "userId": userId, "name": name]

        case let .roomBackground(roomId, background):
            return ["type": "room:bg", "roomId": roomId, "background": background]

        case let .seatChange(seat):
            return ["type": "seat:change", "seat": seat]

        case let .micToggle(muted):
            return ["type": "mic:toggle", "muted": muted]

        case let .chat(userId, text):
            return ["type": "chat", "userId": userId, "text": text]

        case let .giftSend(userId, giftId, count, toClientId):
            return ["type": "gift:send", "userId": userId, "giftId": giftId,
                    "count": count, "toClientId": toClientId]

        case let .musicAdd(title, artist, url, by, libraryId):
            var p: [String: Any] = ["type": "music:add", "title": title, "url": url, "by": by]
            if !artist.isEmpty { p["artist"] = artist }
            if let libraryId { p["libraryId"] = libraryId }
            return p

        case let .musicPlayNow(libraryId, by, title, artist):
            var p: [String: Any] = ["type": "music:play-now", "libraryId": libraryId, "by": by]
            if let title { p["title"] = title }
            if let artist, !artist.isEmpty { p["artist"] = artist }
            return p

        case let .musicControl(action, songId):
            var p: [String: Any] = ["type": "music:control", "action": action]
            if let songId { p["songId"] = songId }
            return p

        case let .rtcOffer(to, sdp):
            return ["type": "rtc:offer", "to": to, "data": ["type": "offer", "sdp": sdp]]

        case let .rtcAnswer(to, sdp):
            return ["type": "rtc:answer", "to": to, "data": ["type": "answer", "sdp": sdp]]

        case let .rtcIce(to, candidate):
            return ["type": "rtc:ice", "to": to, "data": candidate]

        case let .rtcBye(to):
            return ["type": "rtc:bye", "to": to]
        }
    }
}

// MARK: - 服务端下行消息

enum VRServerMessage {
    case authOK(userId: String, user: VRUser, giftList: [VRGift])
    case profileOK(VRUser)
    case vipOK(VRUser)
    case vipFail(String)
    case roomCreated(id: String, no: String, name: String)
    case roomList([VRRoomSummary])
    case roomMy(VRMyRoom?)
    case roomDestroyed(roomId: String)
    case roomClosed(reason: String)
    case roomKicked(reason: String)
    case joinOK(clientId: String, roomId: String, userId: String)
    case joinFail(String)
    case roomState(VRRoomState)
    case peerNew(clientId: String, userId: String)
    case peerBye(clientId: String)
    case chat(VRChatMessage)
    case gift(VRGiftEvent)
    case coinsUpdate(coins: Int, charm: Int)
    case charmUpdate(VRUser)
    case rtcOffer(from: String, sdp: String)
    case rtcAnswer(from: String, sdp: String)
    case rtcIce(from: String, candidate: [String: Any])
    case rtcBye(from: String)
    case error(String)
    case unknown(String)

    static func parse(_ json: [String: Any]) -> VRServerMessage {
        let type = json["type"] as? String ?? ""
        let data = json["data"] as? [String: Any]

        switch type {
        case "auth:ok":
            guard let d = data,
                  let userId = d["userId"] as? String,
                  let u = decode(VRUser.self, d["user"]),
                  let gifts = decode([VRGift].self, d["giftList"])
            else { return .error("登录响应解析失败") }
            return .authOK(userId: userId, user: u, giftList: gifts)

        case "profile:ok":
            guard let d = data, let u = decode(VRUser.self, d) else { return .error("资料更新失败") }
            return .profileOK(u)

        case "vip:ok":
            guard let d = data, let u = decode(VRUser.self, d) else { return .error("VIP 激活失败") }
            return .vipOK(u)

        case "vip:fail":
            return .vipFail(json["msg"] as? String ?? "VIP 码无效")

        case "room:created":
            guard let d = data, let id = d["id"] as? String,
                  let no = d["no"] as? String, let name = d["name"] as? String
            else { return .error("房间创建失败") }
            return .roomCreated(id: id, no: no, name: name)

        case "room:list":
            guard let list = decode([VRRoomSummary].self, json["data"]) else { return .roomList([]) }
            return .roomList(list)

        case "room:my":
            if let d = data, let mine = decode(VRMyRoom.self, d) { return .roomMy(mine) }
            return .roomMy(nil)

        case "room:destroyed":
            let rid = (data?["roomId"] as? String) ?? ""
            return .roomDestroyed(roomId: rid)

        case "room:closed":
            let reason = (data?["reason"] as? String) ?? "房主解散了房间"
            return .roomClosed(reason: reason)

        case "room:kicked":
            let reason = (data?["reason"] as? String) ?? "你的账号在其他地方登录了"
            return .roomKicked(reason: reason)

        case "join:ok":
            guard let d = data, let cid = d["clientId"] as? String,
                  let rid = d["roomId"] as? String, let uid = d["userId"] as? String
            else { return .error("加入房间失败") }
            return .joinOK(clientId: cid, roomId: rid, userId: uid)

        case "join:fail":
            return .joinFail(json["msg"] as? String ?? "进入失败")

        case "room:state":
            guard let d = data, let st = decode(VRRoomState.self, d) else { return .error("房间状态解析失败") }
            return .roomState(st)

        case "peer:new":
            guard let d = data, let cid = d["clientId"] as? String,
                  let uid = d["userId"] as? String else { return .unknown(type) }
            return .peerNew(clientId: cid, userId: uid)

        case "peer:bye":
            guard let d = data, let cid = d["clientId"] as? String else { return .unknown(type) }
            return .peerBye(clientId: cid)

        case "chat":
            guard let d = data, let m = decode(VRChatMessage.self, d) else { return .unknown(type) }
            return .chat(m)

        case "gift":
            guard let d = data, let ev = decode(VRGiftEvent.self, d) else { return .unknown(type) }
            return .gift(ev)

        case "coins:update":
            guard let d = data, let c = d["coins"] as? Int, let ch = d["charm"] as? Int
            else { return .unknown(type) }
            return .coinsUpdate(coins: c, charm: ch)

        case "charm:update":
            guard let d = data, let u = decode(VRUser.self, d["user"]) else { return .unknown(type) }
            return .charmUpdate(u)

        case "rtc:offer":
            guard let from = json["from"] as? String,
                  let d = json["data"] as? [String: Any],
                  let sdp = d["sdp"] as? String else { return .unknown(type) }
            return .rtcOffer(from: from, sdp: sdp)

        case "rtc:answer":
            guard let from = json["from"] as? String,
                  let d = json["data"] as? [String: Any],
                  let sdp = d["sdp"] as? String else { return .unknown(type) }
            return .rtcAnswer(from: from, sdp: sdp)

        case "rtc:ice":
            guard let from = json["from"] as? String,
                  let d = json["data"] as? [String: Any] else { return .unknown(type) }
            return .rtcIce(from: from, candidate: d)

        case "rtc:bye":
            let from = json["from"] as? String ?? ""
            return .rtcBye(from: from)

        case "error":
            return .error(json["msg"] as? String ?? "操作失败")

        default:
            return .unknown(type)
        }
    }

    // MARK: 泛型解码辅助（JSONSerialization 的 Any → Codable）
    private static func decode<T: Decodable>(_ type: T.Type, _ any: Any?) -> T? {
        guard let any else { return nil }
        guard JSONSerialization.isValidJSONObject(any),
              let data = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
