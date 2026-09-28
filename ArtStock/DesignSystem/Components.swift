//
//  Components.swift
//  ArtAssist — 美术生的工具箱
//
//  跨页面复用的展示组件。
//

import SwiftUI

// MARK: - 颜料格子

/// 7×6 网格里的一格。
///
/// 这是整个 App 最核心的视觉元素，用户一屏要看到 42 个。
/// 所以它必须**靠颜色本身说话**，不靠文字；状态只用一条细边和角标表达。
struct PaletteCellView: View {

    let well: PaletteWell
    var isSelected: Bool = false

    private var swatch: Color {
        if let hex = well.color?.hex, let color = Color(hex: hex) {
            return color
        }
        if well.color != nil {
            // 有颜色但没色值：用中性占位，靠别处的文字区分。
            return Color(uiColor: .secondarySystemFill)
        }
        return Theme.emptyWellFill
    }

    private var hasColor: Bool { well.color != nil }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.cellCornerRadius, style: .continuous)
                .fill(swatch)

            // 空格子画虚线框，与"有颜色但缺色值"区分开
            if !hasColor {
                RoundedRectangle(cornerRadius: Theme.cellCornerRadius, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
            }

            // 底部余量条：只在有颜色且不满时出现，避免 42 格全是绿条
            if hasColor, well.level != .full {
                VStack {
                    Spacer(minLength: 0)
                    GeometryReader { geometry in
                        Capsule()
                            .fill(Theme.color(for: well.level))
                            .frame(width: geometry.size.width * well.level.fill, height: 4)
                    }
                    .frame(height: 4)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
            }

            // 左上角位置编号，方便和实物对照
            VStack {
                HStack {
                    Text(well.positionLabel)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(hasColor ? .white.opacity(0.9) : Color(uiColor: .tertiaryLabel))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background {
                            if hasColor {
                                Capsule().fill(.black.opacity(0.3))
                            }
                        }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(5)

            // 需要补的格子：右上角醒目标记
            if hasColor, well.level.needsRefill {
                VStack {
                    HStack {
                        Spacer(minLength: 0)
                        Image(systemName: well.level == .empty
                              ? "exclamationmark.circle.fill" : "exclamationmark.circle")
                            .font(.system(size: 13, weight: .bold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Theme.color(for: well.level))
                    }
                    Spacer(minLength: 0)
                }
                .padding(4)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cellCornerRadius, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent : Theme.wellBorder,
                              lineWidth: isSelected ? 2.5 : 0.5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let color = well.color else { return "\(well.positionLabel) 空格" }
        return "\(well.positionLabel) \(color.name)，余量\(well.level.displayName)"
    }
}

// MARK: - 余量徽标

struct WellLevelBadge: View {
    let level: WellLevel
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: level.symbolName)
                .font(.caption2)
            if !compact {
                Text(level.displayName)
                    .font(.caption.weight(.medium))
            }
        }
        .foregroundStyle(Theme.color(for: level))
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, 4)
        .background(Theme.tint(for: level), in: Capsule())
    }
}

// MARK: - 库存状态徽标

struct StockStateBadge: View {
    let state: ColorStockState

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.color(for: state))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.color(for: state).opacity(0.14), in: Capsule())
    }

    private var text: String {
        switch state {
        case .mustBuy: return "该买"
        case .canRefill: return "该补"
        case .overstocked: return "偏多"
        case .fine: return "够用"
        case .unassigned: return "未装盒"
        }
    }
}

// MARK: - 颜色圆点

struct ColorDot: View {
    let hex: String
    var size: CGFloat = 22

    var body: some View {
        Circle()
            .fill(Color(hex: hex) ?? Color(uiColor: .tertiarySystemFill))
            .frame(width: size, height: size)
            .overlay {
                Circle().strokeBorder(Theme.wellBorder, lineWidth: 0.5)
            }
    }
}

// MARK: - 键值信息行

struct InfoRow: View {
    let label: String
    let value: String
    var symbolName: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            HStack(spacing: 6) {
                if let symbolName {
                    Image(systemName: symbolName)
                        .font(.caption)
                        .foregroundStyle(tint)
                }
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 92, alignment: .leading)

            Text(value.isBlank ? "—" : value)
                .font(.subheadline)
                .foregroundStyle(value.isBlank ? .tertiary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - 分组标题

struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 空状态

struct EmptyState: View {
    let title: String
    let message: String
    let symbolName: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbolName)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

// MARK: - 提示条

struct NoticeBanner: View {
    enum Level {
        case info, warning, error, success

        var tint: Color {
            switch self {
            case .info: return .blue
            case .warning: return .orange
            case .error: return .red
            case .success: return .green
            }
        }

        var symbolName: String {
            switch self {
            case .info: return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error: return "xmark.octagon.fill"
            case .success: return "checkmark.circle.fill"
            }
        }
    }

    let level: Level
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: level.symbolName)
                .foregroundStyle(level.tint)
                .font(.callout)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .background(level.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(level.tint.opacity(0.25), lineWidth: 0.5)
        }
    }
}

// MARK: - 整数步进器

/// 整数步进器。用于"还有几支""还有几个"。
struct IntStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 0...999
    var suffix: String?

    var body: some View {
        HStack(spacing: 12) {
            stepButton(symbol: "minus", delta: -1)

            HStack(spacing: 4) {
                Text("\(value)")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let suffix {
                    Text(suffix)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 58)

            stepButton(symbol: "plus", delta: 1)
        }
    }

    private func stepButton(symbol: String, delta: Int) -> some View {
        let atLimit = delta < 0 ? value <= range.lowerBound : value >= range.upperBound
        return Button {
            value = min(max(value + delta, range.lowerBound), range.upperBound)
            Haptics.selection()
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 42, height: 42)
                .background(Color(uiColor: .secondarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(atLimit)
        .opacity(atLimit ? 0.35 : 1)
        .accessibilityLabel(delta > 0 ? "增加" : "减少")
    }
}
