import SwiftUI

// MARK: - 设计系统
//
// 与网页版保持一致的视觉语言：深色玻璃拟态 + 紫蓝渐变品牌色

enum VRTheme {

    // MARK: 颜色
    static let bg          = Color(hex: "0B1020")
    static let bg2         = Color(hex: "121936")
    static let panel       = Color.white.opacity(0.07)
    static let border      = Color.white.opacity(0.12)
    static let text        = Color(hex: "F2F5FF")
    static let textDim     = Color(hex: "F2F5FF").opacity(0.62)
    static let textMute    = Color(hex: "F2F5FF").opacity(0.38)

    static let brand       = Color(hex: "7B6BFF")
    static let brand2      = Color(hex: "4FC3F7")
    static let pink        = Color(hex: "FF5F98")
    static let gold        = Color(hex: "FFC93C")
    static let green       = Color(hex: "38D39F")
    static let red         = Color(hex: "FF5C6C")

    // MARK: 渐变
    static let brandGradient = LinearGradient(
        colors: [brand, Color(hex: "9D6BFF"), brand2],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let pinkGradient = LinearGradient(
        colors: [pink, Color(hex: "FF8A5B")],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static let goldGradient = LinearGradient(
        colors: [Color(hex: "FFD86B"), Color(hex: "FF9F1C")],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    // MARK: 圆角
    static let radius: CGFloat = 18
    static let radiusSm: CGFloat = 12

    // MARK: 房间背景渐变
    static func background(for id: String) -> [Color] {
        switch RoomBackground(safeRaw: id) {
        case .aurora:
            return [Color(hex: "3B2E8F"), Color(hex: "171B45"), Color(hex: "080B1A")]
        case .hearts:
            return [Color(hex: "3D1140"), Color(hex: "7A1E52"), Color(hex: "C2456B")]
        }
    }

    /// 房间背景上的光晕（叠加层）
    static func glowColors(for id: String) -> [Color] {
        switch RoomBackground(safeRaw: id) {
        case .aurora:
            return [brand.opacity(0.55), brand2.opacity(0.42), pink.opacity(0.35)]
        case .hearts:
            return [pink.opacity(0.4), gold.opacity(0.18)]
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
