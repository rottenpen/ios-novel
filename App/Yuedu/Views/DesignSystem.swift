import SwiftUI

/// 界面共用的语义颜色、字体、间距和动效；正文主题由 ReadTheme 管理。
enum DS {

    // MARK: - 间距标度（4pt 基准）

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
    }

    // MARK: - 圆角

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 20
        /// 封面圆角
        static let cover: CGFloat = 8
    }

    // MARK: - 封面尺寸

    enum Cover {
        /// 书架网格封面宽度
        static let gridWidth: CGFloat = 104
        /// 标准 2:3 比例
        static let ratio: CGFloat = 3.0 / 2.0
        static var gridHeight: CGFloat { gridWidth * ratio }
        /// 列表 / 搜索结果封面
        static let listWidth: CGFloat = 60
        static var listHeight: CGFloat { listWidth * ratio }
        /// 详情页大封面
        static let detailWidth: CGFloat = 120
        static var detailHeight: CGFloat { detailWidth * ratio }
    }

    // MARK: - 动效

    enum Motion {
        static let quick: Animation = .easeOut(duration: 0.18)
        static let standard: Animation = .spring(response: 0.35, dampingFraction: 0.85)
        static let gentle: Animation = .easeInOut(duration: 0.25)
    }

    // MARK: - 品牌色

    /// 主色：墨青，偏冷的沉稳色，长时间阅读不刺眼
    static let accent = Color(light: .init(hex: 0x2C6E63), dark: .init(hex: 0x4FA396))
    /// 次要强调：暖橙，用于更新提示、角标
    static let highlight = Color(light: .init(hex: 0xD97706), dark: .init(hex: 0xF59E0B))

    /// 卡片背景
    static let card = Color(light: .init(hex: 0xFFFFFF), dark: .init(hex: 0x1C1C1E))
    /// 页面背景
    static let canvas = Color(light: .init(hex: 0xF6F6F8), dark: .init(hex: 0x000000))
    /// 分隔线
    static let separator = Color.primary.opacity(0.08)
    /// 封面占位
    static let placeholder = Color.primary.opacity(0.06)
}

// MARK: - Color 便利构造

extension Color {
    /// 十六进制构造
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// 按深浅色模式取不同值
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #else
        self = light
        #endif
    }
}

// MARK: - 通用修饰器

/// 卡片容器样式
struct CardStyle: ViewModifier {
    var padding: CGFloat = DS.Spacing.md

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(DS.card)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
    }
}

extension View {
    func cardStyle(padding: CGFloat = DS.Spacing.md) -> some View {
        modifier(CardStyle(padding: padding))
    }

    /// 轻量胶囊标签
    func chipStyle(color: Color = DS.accent) -> some View {
        self
            .font(.caption2)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xxs)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
