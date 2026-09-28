//
//  Formatters.swift
//  ArtAssist — 美术生的工具箱
//

import Foundation

/// 全应用统一的格式化入口。集中管理避免各处 Locale 不一致。
enum Fmt {

    // MARK: - 数字

    /// 去掉无意义的小数尾零：12.0 → "12"，12.50 → "12.5"。
    static func number(_ value: Double, maximumFractionDigits: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = maximumFractionDigits
        formatter.minimumFractionDigits = 0
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// 百分比整数：0.42 → "42%"。
    static func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    /// 数量 + 单位：`12 张`。
    static func quantity(_ value: Double, unit: String) -> String {
        "\(number(value, maximumFractionDigits: value == value.rounded() ? 0 : 1)) \(unit)"
    }

    // MARK: - 日期

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func date(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    static func dateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    /// 相对时间：`刚刚` / `12 分钟前` / `3 天前`。
    static func relative(_ date: Date) -> String {
        let interval = Date.now.timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 86_400 { return "\(Int(interval / 3600)) 小时前" }
        if interval < 86_400 * 30 { return "\(Int(interval / 86_400)) 天前" }
        return Fmt.date(date)
    }

    /// 时长。用于"距离上次补充过了多久"。
    ///
    /// 刻意做成两段式：补颜料是几天一次的事，精确到分没有意义，
    /// 反而让人以为数据很准。短时长才给到分钟。
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = abs(interval)
        if seconds < 45 { return "刚刚" }

        if seconds < 3600 {
            return "\(Int((seconds / 60).rounded())) 分钟"
        }
        if seconds < 86_400 {
            let hours = Int(seconds / 3600)
            let minutes = Int((seconds.truncatingRemainder(dividingBy: 3600)) / 60)
            if hours >= 6 || minutes == 0 { return "\(hours) 小时" }
            return "\(hours) 小时 \(minutes) 分"
        }
        let days = Int(seconds / 86_400)
        let hours = Int((seconds.truncatingRemainder(dividingBy: 86_400)) / 3600)
        if hours == 0 { return "\(days) 天" }
        return "\(days) 天 \(hours) 小时"
    }
}
