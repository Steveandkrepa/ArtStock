//
//  SupplyItem.swift
//  ArtAssist — 美术生的工具箱
//
//  颜料之外的其他耗材：纸、笔、橡皮、胶带……
//
//  刻意做得很轻。上一版这里是仓库模型（供应商、单价、库存价值、
//  A4 标签打印、CSV 导出、有效期、操作人），那些是库房管理员要的东西，
//  一个美术生只需要知道「还剩多少，够不够用」。
//

import Foundation
import SwiftData

/// 耗材分类。只保留美术生真正会分的那几类。
enum SupplyCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case paper
    case brush
    case eraser
    case tape
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paper: return "纸张"
        case .brush: return "笔"
        case .eraser: return "橡皮"
        case .tape: return "胶带"
        case .other: return "其他"
        }
    }

    var symbolName: String {
        switch self {
        case .paper: return "doc.plaintext"
        case .brush: return "paintbrush.pointed"
        case .eraser: return "eraser"
        case .tape: return "tape"
        case .other: return "shippingbox"
        }
    }

    /// 列表里的分组顺序。
    var sortOrder: Int {
        switch self {
        case .paper: return 0
        case .brush: return 1
        case .eraser: return 2
        case .tape: return 3
        case .other: return 4
        }
    }
}

@Model
final class SupplyItem {

    var name: String
    var categoryRaw: String

    /// 当前数量。
    var quantity: Double
    /// 单位：张、支、块、卷……
    var unit: String

    /// 低于这个数量就提醒补。0 表示不提醒。
    var lowThreshold: Double

    /// 「满」的时候是多少（一包纸 100 张、一盒橡皮 12 块）。
    ///
    /// 用可选值而不是 `Double = 0`：新增可选属性在 SwiftData 里
    /// **一定**能轻量迁移，而带默认值的非可选属性虽然通常也行，
    /// 万一迁移失败就会掉到内存库、用户看到"数据没了"。
    /// 这个字段只影响视觉，不值得冒那个风险。
    ///
    /// nil = 没设。设了之后卡片上才有"余量条"，也才谈得上比例。
    var fullCapacityValue: Double?

    /// 用户最近用过的单位（用逗号分隔存着，供选择器做快捷项）。
    ///
    /// ⚠️⚠️ **必须可选，不能写成 `var recentUnitsRaw: String`。**
    ///
    /// 这一行造成过一次真实的数据事故：新增**非可选且无默认值**的属性时，
    /// SwiftData（底层 Core Data）的轻量迁移会失败 —— 整个 store 打不开。
    /// 而启动代码在打不开时会降级到内存库，表现就是
    /// **"数据全丢了、预设也重新来过"**，而且看不出是迁移的问题。
    ///
    /// 规则记在这里，别再犯：**给已有的 @Model 加字段，
    /// 只能是可选类型 `T?`，或者带默认值 `= ...`。**
    /// 这条现在由 `scripts/check-model-migration.py` 自动守着。
    var recentUnitsRaw: String?

    var note: String
    var createdAt: Date
    var updatedAt: Date

    init(
        name: String,
        category: SupplyCategory = .other,
        quantity: Double = 0,
        unit: String = "个",
        lowThreshold: Double = 0,
        fullCapacity: Double? = nil,
        note: String = "",
        createdAt: Date = .now
    ) {
        self.name = name
        self.categoryRaw = category.rawValue
        self.quantity = max(0, quantity)
        self.unit = unit
        self.lowThreshold = max(0, lowThreshold)
        self.fullCapacityValue = (fullCapacity ?? 0) > 0 ? fullCapacity : nil
        self.recentUnitsRaw = ""
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

// MARK: - 枚举桥接

extension SupplyItem {

    var category: SupplyCategory {
        get { SupplyCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }
}

// MARK: - 余量与档位

extension SupplyItem {

    /// 「满」是多少。0 表示没设。
    var fullCapacity: Double {
        get { fullCapacityValue ?? 0 }
        set { fullCapacityValue = newValue > 0 ? newValue : nil }
    }

    var hasFullCapacity: Bool { fullCapacity > 0 }

    /// 余量档位。跟颜料盒的"五档"是同一套语言。
    var level: SupplyLevel {
        StockPlan.level(quantity: quantity, fullCapacity: fullCapacity, lowThreshold: lowThreshold)
    }

    /// 余量比例（0…1）。没设满量时为 nil —— 没有参照就不编比例。
    var remainingFraction: Double? {
        StockPlan.remainingFraction(quantity: quantity, fullCapacity: fullCapacity)
    }

    /// 卡片上画余量条用的比例。没设满量时退回档位的代表值，
    /// 至少让用户看得出"这条大概多满"。
    var barFraction: Double {
        remainingFraction ?? level.barFraction
    }

    /// 最近用过的单位。
    var recentUnits: [String] {
        (recentUnitsRaw ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 记下一个用过的单位（最多留 8 个，最近的排前面）。
    func rememberUnit(_ unit: String) {
        let trimmed = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = recentUnits.filter { $0 != trimmed }
        list.insert(trimmed, at: 0)
        recentUnitsRaw = list.prefix(8).joined(separator: ",")
    }

    /// 只能这样写：可选存储 + 计算属性对外提供非可选值。
    /// （直接暴露可选的原始值会让调用点到处 `?? ""`。）
    var recentUnitsText: String { recentUnitsRaw ?? "" }
}

// MARK: - 派生

extension SupplyItem {

    /// 是否低于提醒线。阈值为 0 时永不提醒。
    var isLow: Bool {
        lowThreshold > 0 && quantity <= lowThreshold
    }

    var isOut: Bool {
        quantity <= 0
    }

    /// 数量文案：离散单位不带小数。
    var quantityText: String {
        let text = Fmt.number(quantity, maximumFractionDigits: quantity == quantity.rounded() ? 0 : 1)
        return "\(text) \(unit)"
    }

    var statusText: String {
        if isOut { return "已用完" }
        if isLow { return "该补了" }
        return "够用"
    }
}

// MARK: - 接入统一库存体系

extension SupplyItem {

    /// 交给 `StockPlan` 的取值快照。
    ///
    /// 把 @Model 和纯逻辑隔开 —— 这样"该不该买"的判断能在 macOS 上跑测试。
    var snapshot: SupplySnapshot {
        SupplySnapshot(
            name: name,
            categoryName: category.displayName,
            categoryOrder: category.sortOrder,
            quantity: quantity,
            unit: unit,
            lowThreshold: lowThreshold
        )
    }

    /// 该不该补。统一走 `StockPlan`，避免两处判断不一致。
    var needsRestock: Bool {
        StockPlan.needsRestock(snapshot)
    }

    /// 为什么该补。
    var restockReason: String {
        StockPlan.reason(for: snapshot)
    }
}
