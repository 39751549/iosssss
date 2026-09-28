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
}

/// 大厅列表里的房间（带在线人数）
struct VRRoomSummary: Codable, Identifiable, Equatable {
    var id: String
    var no: String
    var name: String
    var background: String
    var count: Int
    var ownerId: String
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
}

// MARK: - 房间完整状态快照

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

    /// 按麦位号取成员
    func member(atSeat seat: Int) -> VRMember? {
        members.first { $0.seat == seat }
    }

    func member(clientId: String) -> VRMember? {
        members.first { $0.clientId == clientId }
    }
}

// MARK: - 房间背景主题

enum RoomBackground: String, CaseIterable, Identifiable {
    case aurora, hearts   // 默认只保留 2 个主题，其余靠自定义背景图
    var id: String { rawValue }

    var label: String {
        switch self {
        case .aurora: return "极光"
        case .hearts: return "爱心雨"
        }
    }

    var icon: String {
        switch self {
        case .aurora: return "🌌"
        case .hearts: return "💖"
        }
    }

    /// 是否带动态粒子层
    var isDynamic: Bool {
        switch self {
        case .hearts: return true
        default: return false
        }
    }

    init(safeRaw: String) {
        // 旧数据里的 sunset/night 等主题已下线，回退到极光
        self = RoomBackground(rawValue: safeRaw) ?? .aurora
    }
}
