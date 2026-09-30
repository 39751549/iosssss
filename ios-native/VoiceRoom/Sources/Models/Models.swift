import Foundation

// MARK: - 用户

struct VRUser: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var avatar: String        // dataURL 或 http URL，空串表示用生成头像
    var gender: Gender
    var bio: String
    var coins: Int
    var charm: Int
    var vip: Bool
    var vipLevel: Int
    /// 当前穿戴的头像框 id（空 = 不戴，只显示 VIP 等级环）
    var frame: String?
    /// 已拥有的头像框 id 列表（背包）。默认框不占背包位，人人都有。
    var frames: [String]?

    static func placeholder(id: String = "local") -> VRUser {
        VRUser(id: id, name: "游客", avatar: "", gender: .secret, bio: "",
               coins: 0, charm: 0, vip: false, vipLevel: 0)
    }

    /// 是否设置了自定义头像
    var hasCustomAvatar: Bool { !avatar.isEmpty }

    /// 名字首字，用于生成默认头像
    var initial: String {
        String(name.trimmingCharacters(in: .whitespaces).first ?? "?").uppercased()
    }
}

enum Gender: String, Codable, CaseIterable, Identifiable {
    case male, female, secret
    var id: String { rawValue }

    var label: String {
        switch self {
        case .male: return "男生"
        case .female: return "女生"
        case .secret: return "保密"
        }
    }

    var symbol: String {
        switch self {
        case .male: return "♂"
        case .female: return "♀"
        case .secret: return "?"
        }
    }

    /// 未知值兜底，避免服务端返回新枚举时解析失败
    init(safeRaw: String) {
        self = Gender(rawValue: safeRaw) ?? .secret
    }
}

// MARK: - 房间

struct VRRoom: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var no: String
    var background: String
    var ownerId: String
    /// 房间头像（房主上传，圆形展示）。空 = 退回背景缩略图 / 名字首字。
    var avatar: String?
    /// 房主是不是 VIP —— 是的话房间号显示成金色
    var ownerVip: Bool?
}

/// 大厅列表里的房间（带在线人数）
struct VRRoomSummary: Codable, Identifiable, Equatable {
    var id: String
    var no: String
    var name: String
    var background: String
    var count: Int
    var ownerId: String
    var avatar: String?
    var ownerVip: Bool?
}

/// 我的永久房间（room:my 返回，可能没有）
struct VRMyRoom: Codable, Identifiable, Equatable {
    var id: String
    var no: String
    var name: String
    var background: String
    var ownerId: String
    var count: Int
    var createdAt: Double
    var avatar: String?
    var ownerVip: Bool?
}

/// 头像框（商城可买 / 背包可穿戴）。
///
/// 样式不在客户端写死：服务端给出配色和角标，客户端统一渲染成「渐变环 + 可选角标 + 可选外发光」，
/// 以后加新头像框只要在服务端 config.avatarFrames 里加一条就行，不用发版。
///
/// 图片头像框（img 非空）：服务端直接下发一张 264x264、中心透明的 PNG，
/// 客户端把它原样叠在头像上 —— 框的美术完全由素材决定，渐变环只做老版本的兜底
/// （新框 + 老 App：老 App 不认识 img，退回画 colors 渐变环，不至于显示成白圈）。
struct VRAvatarFrame: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// 金币价格；0 = 默认框（人人都有，不占背包）
    var price: Int
    /// 渐变环颜色（hex，2-3 个）；图片框时可空（老版本兜底用）
    var colors: [String]
    /// 图片素材地址（/frames/xxx.png，264x264 中心透明）。nil = 渐变环框
    var img: String?
    /// 角标 emoji（可空）
    var badge: String?
    /// 是否带外发光
    var glow: Bool?
    /// 稀有度：normal / rare / epic / legend。仅影响商城的标签配色
    var tier: String?
}

// MARK: - 房间成员（麦位）

struct VRMember: Codable, Identifiable, Equatable {
    var clientId: String
    var user: VRUser
    var seat: Int              // -1 表示在听众席
    var muted: Bool
    var joinedAt: Double

    var id: String { clientId }
    var onMic: Bool { seat >= 0 }
}

// MARK: - 聊天消息

struct VRChatMessage: Codable, Identifiable, Equatable {
    var id: String
    var sys: Bool?
    var text: String
    var userId: String?
    var name: String?
    var avatar: String?
    var vip: Bool?
    var vipLevel: Int?
    var at: Double

    var isSystem: Bool { sys == true }

    /// 时间显示 HH:mm
    var timeText: String {
        let d = Date(timeIntervalSince1970: at / 1000)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

// MARK: - 礼物

struct VRGift: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var emoji: String
    var price: Int
    var charm: Int
}

/// 礼物飘屏事件
struct VRGiftEvent: Codable, Equatable {
    var id: String
    var from: VRUser
    var toClientId: String?
    var gift: GiftBrief
    var count: Int
    var at: Double

    struct GiftBrief: Codable, Equatable {
        var id: String
        var name: String
        var emoji: String
    }
}

// MARK: - 歌曲

struct VRSong: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var url: String
    var by: String
    var at: Double
    /// 歌手（服务端可能不下发，容错为 nil）
    var artist: String?
    /// 曲库标识：本地曲库为 libId；在线曲库为 gd|源|歌id
    var libraryId: String?
    /// 点歌人的 userId —— 用来把「正在播放的这首歌是谁点的」那个麦位点亮。
    /// 老数据/老服务端没有这个字段，所以是可选的。
    var byUserId: String?
}

// MARK: - 房间完整状态快照

/// 播放模式：列表循环 / 单曲循环 / 列表播完结束
enum VRPlayMode: String, Codable, CaseIterable, Identifiable {
    case order   // 列表循环
    case single  // 单曲循环
    case once    // 列表播完结束

    var id: String { rawValue }

    var label: String {
        switch self {
        case .order:  return "列表循环"
        case .single: return "单曲循环"
        case .once:   return "播完结束"
        }
    }

    var icon: String {
        switch self {
        case .order:  return "🔁"
        case .single: return "🔂"
        case .once:   return "➡️"
        }
    }

    /// 依次切换：列表循环 → 单曲循环 → 播完结束
    var next: VRPlayMode {
        switch self {
        case .order:  return .single
        case .single: return .once
        case .once:   return .order
        }
    }

    init(safeRaw: String) {
        self = VRPlayMode(rawValue: safeRaw) ?? .order
    }
}

struct VRRoomState: Codable, Equatable {
    var room: VRRoom
    var members: [VRMember]
    var seats: [String?]
    var hostClientId: String?
    var playlist: [VRSong]
    var currentSong: VRSong?
    var playing: Bool
    var startedAt: Double
    var now: Double
    var chatLog: [VRChatMessage]
    var giftList: [VRGift]
    /// 播放模式（服务端下发，缺省为列表循环）
    var playMode: String?
    /// 管理员设置的全局背景模板（对所有房间通用；相对路径 /bg/xxx.gif）
    var globalBg: String?

    /// 播放模式（安全解析）
    var mode: VRPlayMode { VRPlayMode(safeRaw: playMode ?? "order") }

    /// 有效背景：房间级自定义背景优先；否则用全局模板
    var effectiveBackground: String {
        let rb = room.background
        // 房间背景是上传的图片/GIF（以 / 或 http 开头）→ 直接用
        if rb.hasPrefix("/") || rb.hasPrefix("http") { return rb }
        // 否则用全局模板（管理员上传，对所有房间通用）
        if let g = globalBg, !g.isEmpty { return g }
        return rb
    }

    /// 按麦位号取成员
    func member(atSeat seat: Int) -> VRMember? {
        members.first { $0.seat == seat }
    }

    func member(clientId: String) -> VRMember? {
        members.first { $0.clientId == clientId }
    }

    /// 这个人是不是房主。
    ///
    /// 用 `room.ownerId` 判定，而不是 `hostClientId`：后者的语义是"坐在 0 号主位的是谁"，
    /// 而服务端**允许房主离开主位换到 1-8 号麦**（0 号位空着，宾客也坐不了）。
    /// 房主一换位，靠 hostClientId 就认不出他了 —— 金环、皇冠、房主徽章会整片消失。
    /// ownerId 由服务端持久化，跟着人不跟着座位走。
    func isOwner(_ m: VRMember?) -> Bool {
        guard let m, !room.ownerId.isEmpty else { return false }
        return m.user.id == room.ownerId
    }
}

// MARK: - 房间内置背景（写死的 5 张）

/// 内置房间背景：**固定 5 张**，由客户端写死，用户不可增删。
///
/// 为什么用「服务端路径」当 id，而不是把图打进 App 包：
/// 1) 同一套 id 在 iOS / Web 两端通用，房主换了背景，两端看到的都一样；
/// 2) 这 5 张动图加起来 11MB，打进包里 IPA 会翻三倍；
/// 3) 图片走 MediaCache 按 URL 缓存（内存 + 磁盘两级），第一次看过之后本地就有，
///    后续进出房间、切后台回来都是瞬时命中，不再走网络。
///
/// 老房间存的是 aurora / hearts 这类已下线的主题名 —— 一律按默认背景显示，
/// 不会出现「背景空白」。
struct RoomBackground: Identifiable, Hashable {

    /// 存储 / 传输用的值（即服务端 room.background 字段），形如 "/presets/preset-1.gif"
    let id: String
    let label: String
    /// 兜底渐变色号：图片还没就位时先顶上，避免白屏闪一下
    let colors: [String]

    var rawValue: String { id }

    /// 写死的 5 个内置背景（顺序 = 背景文件夹里的顺序）
    static let presets: [RoomBackground] = [
        RoomBackground(id: "/presets/preset-1.gif", label: "紫海",
                       colors: ["BFE3FF", "DCEBFF", "FFF7EA"]),
        RoomBackground(id: "/presets/preset-2.gif", label: "幻月",
                       colors: ["D9E4FF", "E9D9F5", "FFF0E6"]),
        RoomBackground(id: "/presets/preset-3.gif", label: "小鹿",
                       colors: ["E4D9FF", "F3E6FF", "FFF3EA"]),
        RoomBackground(id: "/presets/preset-4.gif", label: "星云",
                       colors: ["FFE3F1", "E5E6FF", "E2F6FF"]),
        RoomBackground(id: "/presets/preset-5.gif", label: "云海",
                       colors: ["FFE0EF", "F4D9FF", "FFEEDF"])
    ]

    /// 默认背景：新房间、清掉自定义背景后都回到这张
    static let fallback: RoomBackground = RoomBackground.presets[0]

    /// 精确匹配内置背景；不是内置的返回 nil
    static func match(_ raw: String) -> RoomBackground? {
        presets.first { $0.id == raw }
    }

    /// 把服务端下发的 background 解析成内置背景。
    /// 老主题名（aurora / hearts…）与空值统一落到默认背景。
    static func resolved(_ raw: String) -> RoomBackground {
        match(raw) ?? fallback
    }

    /// 是否是「用户上传的自定义背景」（以 / 或 http 开头，且不是内置的那 5 张）
    static func isCustom(_ raw: String) -> Bool {
        guard raw.hasPrefix("/") || raw.hasPrefix("http") else { return false }
        return match(raw) == nil
    }

    /// 是否是图片背景（内置图或自定义图）—— 决定要不要去加载图片
    static func isImage(_ raw: String) -> Bool {
        raw.hasPrefix("/") || raw.hasPrefix("http")
    }
}
