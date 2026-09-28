//
//  Extensions.swift
//  ArtAssist — 美术生的工具箱
//

import SwiftUI
import UIKit

// MARK: - 颜色

extension Color {

    /// 从 `#RRGGBB` / `#RGB` 十六进制字符串构造颜色。非法输入返回 nil。
    init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 3 || cleaned.count == 6, cleaned.allSatisfy(\.isHexDigit) else { return nil }

        if cleaned.count == 3 {
            cleaned = cleaned.map { "\($0)\($0)" }.joined()
        }

        guard let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// 转成 `#RRGGBB`。用于把 ColorPicker 的选择写回模型。
    func toHex() -> String? {
        let uiColor = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}

// MARK: - 视图样式

extension View {

    /// 统一的卡片外观：圆角、背景、细描边。
    /// 用 UIKit 语义色而不是 `.background.secondary` 这类组合，避免不同系统版本上的解析差异。
    func cardStyle(padding: CGFloat = Theme.cardPadding) -> some View {
        self
            .padding(padding)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5)
            }
    }

    /// 条件修饰符，避免为布尔分支写两份视图。
    @ViewBuilder
    func applyIf<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - 数组

extension Array where Element: Identifiable {

    /// 按 id 去重，保留首次出现。批量扫码时同一码被连续扫到会导致重复。
    func deduplicatedByID() -> [Element] {
        var seen = Set<Element.ID>()
        return filter { seen.insert($0.id).inserted }
    }
}

extension Array {

    /// 安全下标访问。
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Binding

extension Binding {

    /// 提供默认值的 Binding 解包，常用于 Optional 字段绑定到非 Optional 控件。
    func replacingNil<T>(with defaultValue: T) -> Binding<T> where Value == T? {
        Binding<T>(
            get: { wrappedValue ?? defaultValue },
            set: { wrappedValue = $0 }
        )
    }
}

extension Binding {

    /// 由 `Binding<T?>` 派生出的「是否有值」布尔 Binding。
    ///
    /// 专门用于 `.alert(_:isPresented:)` / `.sheet(isPresented:)` 这类只接受
    /// `Binding<Bool>` 的 API —— 写成 `.constant(x != nil)` 会导致弹窗关不掉，
    /// 因为 constant 永远不回写。这里在置 false 时把源值清空。
    static func presentWhen<T>(_ source: Binding<T?>) -> Binding<Bool> {
        Binding<Bool>(
            get: { source.wrappedValue != nil },
            set: { isPresented in
                if !isPresented { source.wrappedValue = nil }
            }
        )
    }
}

// MARK: - 字符串

extension String {

    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isBlank: Bool {
        trimmed.isEmpty
    }

    /// 非空时返回自身，否则返回 nil。用于把空输入转成 Optional 字段。
    var nilIfBlank: String? {
        isBlank ? nil : trimmed
    }
}

// MARK: - Double

extension Double {

    /// 限定在闭区间内。
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
