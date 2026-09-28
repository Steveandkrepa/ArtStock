//
//  Theme.swift
//  ArtAssist — 美术生的工具箱
//
//  颜色与视觉常量。
//
//  配色取向：这是个**画桌旁的 App**，界面要能退到背景里去，
//  让颜料本身的颜色成为画面上唯一的重点。所以除状态色外一律低饱和，
//  背景用系统语义色，不自造主题色。
//

import SwiftUI

enum Theme {

    // MARK: - 布局

    static let cornerRadius: CGFloat = 14
    static let cardPadding: CGFloat = 16
    static let cardSpacing: CGFloat = 12

    /// 网格格子的间距。要足够小才像"一盒"，足够大才能分清边界。
    static let gridSpacing: CGFloat = 8
    /// 格子圆角。
    static let cellCornerRadius: CGFloat = 10

    /// 网格最大宽度。iPad 横屏下太宽会拉得很难看。
    static let maxGridWidth: CGFloat = 760

    // MARK: - 余量状态色

    /// 五档余量的颜色。越少越暖（更醒目）。
    ///
    /// "空"用红、"快没了"用橙 —— 这两个是唯一需要用户立刻注意的状态，
    /// 其余三档用中性或冷色，避免整盒花花绿绿反而看不出重点。
    static func color(for level: WellLevel) -> Color {
        switch level {
        case .empty: return .red
        case .low: return .orange
        case .half: return .yellow
        case .high: return .mint
        case .full: return .green
        }
    }

    /// 状态色的浅底，用于徽标背景。
    static func tint(for level: WellLevel) -> Color {
        color(for: level).opacity(0.15)
    }

    // MARK: - 库存状态色

    static func color(for state: ColorStockState) -> Color {
        switch state {
        case .mustBuy: return .red
        case .canRefill: return .orange
        case .overstocked: return .blue
        case .fine: return .green
        case .unassigned: return .gray
        }
    }

    // MARK: - 网格

    /// 未装颜色的空格子底色。
    static let emptyWellFill = Color(uiColor: .tertiarySystemFill)

    /// 格子边框。
    static let wellBorder = Color(uiColor: .separator).opacity(0.35)

    /// 强调色（跟随 Assets 里的 AccentColor）。
    static let accent = Color.accentColor
}
