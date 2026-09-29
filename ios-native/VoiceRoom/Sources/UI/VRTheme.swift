import SwiftUI

// MARK: - 设计系统
//
// 明亮卡通海岛风：天空蓝 + 奶油白 + 樱花粉，圆角软萌

enum VRTheme {

    // MARK: 颜色
    static let bg          = Color(hex: "EAF6FF")
    static let bg2         = Color(hex: "DDEFFF")
    static let panel       = Color.white.opacity(0.94)
    static let border      = Color(hex: "3D7DBF").opacity(0.14)
    static let text        = Color(hex: "27436B")
    static let textDim     = Color(hex: "27436B").opacity(0.68)
    static let textMute    = Color(hex: "27436B").opacity(0.42)

    static let brand       = Color(hex: "3FA9F5")
    static let brand2      = Color(hex: "FF9EC4")
    static let pink        = Color(hex: "FF7FAE")
    static let gold        = Color(hex: "FFB53C")
    static let green       = Color(hex: "3ECFA0")
    static let red         = Color(hex: "FF6B7D")

    // MARK: 渐变
    static let brandGradient = LinearGradient(
        colors: [brand, Color(hex: "6FC4FF"), brand2],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let pinkGradient = LinearGradient(
        colors: [pink, Color(hex: "FFB199")],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let goldGradient = LinearGradient(
        colors: [Color(hex: "FFD86B"), Color(hex: "FFA53C")],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    // MARK: 圆角
    static let radius: CGFloat = 18
    static let radiusSm: CGFloat = 12

    // MARK: 房间背景渐变（明亮氛围）
    static func background(for id: String) -> [Color] {
        switch RoomBackground(safeRaw: id) {
        case .aurora:
            return [Color(hex: "BFE3FF"), Color(hex: "DCEBFF"), Color(hex: "FFF7EA")]
        case .hearts:
            return [Color(hex: "FFE3EE"), Color(hex: "FFD1E5"), Color(hex: "FFF3E0")]
        }
    }

    /// 房间背景上的光晕（叠加层）
    static func glowColors(for id: String) -> [Color] {
        switch RoomBackground(safeRaw: id) {
        case .aurora:
            return [Color.white.opacity(0.55), brand.opacity(0.28), pink.opacity(0.22)]
        case .hearts:
            return [pink.opacity(0.32), gold.opacity(0.18)]
        }
    }

    // MARK: 头像配色
    static let avatarColors: [Color] = [
        Color(hex: "FF6B8B"), Color(hex: "6BC5FF"), Color(hex: "FFB86B"),
        Color(hex: "8B7BFF"), Color(hex: "5ED3A8"), Color(hex: "FF8FB1"),
        Color(hex: "7ED0FF"), Color(hex: "FFD36B"), Color(hex: "A78BFA"),
        Color(hex: "34D399"), Color(hex: "F472B6"), Color(hex: "60A5FA")
    ]

    static func avatarColor(seed: String) -> Color {
        var h: UInt32 = 0
        for scalar in seed.unicodeScalars {
            h = h &* 31 &+ UInt32(scalar.value)
        }
        return avatarColors[Int(h % UInt32(avatarColors.count))]
    }
}

// MARK: - Color 扩展

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let r, g, b, a: UInt64
        switch hex.count {
        case 6:
            (r, g, b, a) = (int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF, 255)
        case 8:
            (r, g, b, a) = (int >> 24 & 0xFF, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (r, g, b, a) = (0, 0, 0, 255)
        }
        self.init(.sRGB,
                  red: Double(r) / 255,
                  green: Double(g) / 255,
                  blue: Double(b) / 255,
                  opacity: Double(a) / 255)
    }
}
