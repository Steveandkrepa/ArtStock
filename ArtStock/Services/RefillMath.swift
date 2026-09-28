//
//  RefillMath.swift
//  ArtAssist — 美术生的工具箱
//
//  补充装的核心算术。**刻意做成纯函数、只依赖 Foundation。**
//
//  为什么要把这几个函数单独抽出来：
//  "不缺也不过多"这句承诺，实际上就落在三个算术上 ——
//      1. 现有库存够不够补完待补的格子
//      2. 不够的话缺几格
//      3. 缺的这几格该买几件
//  这三步一旦算错，用户要么漏买（颜料断档）要么多买（占地方又费钱），
//  而它们又完全独立于 SwiftData 和界面。所以抽成纯函数，
//  用 Tests/RefillMathTests 直接验证，而不是埋在带 ModelContext 的服务里靠手点。
//

import Foundation

// MARK: - 状态

/// 某个颜色在当前盒子与库存下的处境。
enum ColorStockState: Equatable, Sendable {
    /// 这个颜色还没进盒子。
    case unassigned
    /// 够用，不用管。
    case fine
    /// 有格子该补了，库存够 —— 直接用，别买。
    case canRefill
    /// 有格子该补了，库存不够 —— 需要买。
    case mustBuy
    /// 库存远超需求 —— 别再买了。
    case overstocked
}

// MARK: - 算术

enum RefillMath {

    /// "还能补几次"超过这个数就算库存过多。
    ///
    /// 取 8 的依据：一盒 42 格里，一个颜色通常占 1–3 格。
    /// 还能补 8 格以上意味着够补满两三整盒，明显超出实际消耗节奏。
    static let defaultOverstockCapacity = 8

    // MARK: 判定状态

    /// 判定某个颜色的处境。
    /// - Parameters:
    ///   - needed: 盒子里有几格需要补。
    ///   - capacity: 库存还能补几格（两种补充装之和）。
    ///   - isAssigned: 这个颜色是否已经装进盒子。
    ///   - overstockCapacity: 超过多少算过多。
    static func state(
        needed: Int,
        capacity: Int,
        isAssigned: Bool,
        overstockCapacity: Int = defaultOverstockCapacity
    ) -> ColorStockState {
        guard isAssigned else { return .unassigned }
        if needed <= 0 {
            return capacity > overstockCapacity ? .overstocked : .fine
        }
        return max(0, needed - capacity) > 0 ? .mustBuy : .canRefill
    }

    /// 缺口：还差几格才够补完。
    static func shortage(needed: Int, capacity: Int) -> Int {
        max(0, needed - capacity)
    }

    /// 补完缺口需要买几件。
    ///
    /// 用向上取整：缺 4 格、每件补 3 格时必须买 2 件 ——
    /// 向下取整会漏买，那正是"颜料断档"的来源。
    static func unitsToBuy(shortage: Int, capacityPerUnit: Int) -> Int {
        guard shortage > 0 else { return 0 }
        let perUnit = max(1, capacityPerUnit)
        return Int(ceil(Double(shortage) / Double(perUnit)))
    }

    // MARK: 消耗模拟

    /// 一次补充操作的消耗结果。
    struct Consumption: Equatable, Sendable {
        /// 实际补满了几格。
        var filled: Int
        /// 用掉了几个整单位（新开的支/个）。
        var unitsUsed: Int
        /// 已开封那件补完之后还剩几格可补。
        var remainingPartial: Int
        /// 是否因为库存不足而没补完。
        var wasShort: Bool
        /// 是否动用了已开封的那一件。
        var usedPartial: Bool
    }

    /// 模拟"用一条库存去补 `needed` 格"。
    ///
    /// 消耗顺序刻意是**先用已开封的，再开新的**：
    /// 反过来会让开封的那支永远搁着，实际用颜料时这是最忌讳的 —— 它会先干。
    ///
    /// - Parameters:
    ///   - needed: 需要补的格数。
    ///   - units: 未开封的整件数量。
    ///   - capacityPerUnit: 每件能补几格。
    ///   - partial: 已开封那件还剩几格可补。
    static func consume(
        needed: Int,
        units: Int,
        capacityPerUnit: Int,
        partial: Int
    ) -> Consumption {
        guard needed > 0 else {
            return Consumption(filled: 0, unitsUsed: 0,
                               remainingPartial: max(0, partial),
                               wasShort: false, usedPartial: false)
        }

        let perUnit = max(1, capacityPerUnit)
        var remaining = needed
        var unitsUsed = 0
        var remainingPartial = max(0, partial)
        let startingPartial = remainingPartial

        // 1) 先用已开封那件
        let fromPartial = min(remainingPartial, remaining)
        remainingPartial -= fromPartial
        remaining -= fromPartial

        // 2) 再开新的整件
        while remaining > 0, unitsUsed < max(0, units) {
            unitsUsed += 1
            let used = min(perUnit, remaining)
            remaining -= used
            remainingPartial = perUnit - used
        }

        return Consumption(
            filled: needed - remaining,
            unitsUsed: unitsUsed,
            remainingPartial: remainingPartial,
            wasShort: remaining > 0,
            usedPartial: startingPartial > 0 && fromPartial > 0
        )
    }

    /// 把两种补充装的剩余能力加起来。
    static func totalCapacity(squeezeUnits: Int, squeezePerUnit: Int, squeezePartial: Int,
                              panUnits: Int) -> Int {
        max(0, squeezeUnits) * max(1, squeezePerUnit) + max(0, squeezePartial) + max(0, panUnits)
    }

    // MARK: 文案

    /// 缺口说明。给用户看的一句话。
    static func shortfallExplanation(needed: Int, capacity: Int) -> String {
        let gap = shortage(needed: needed, capacity: capacity)
        if needed <= 0 { return "盒子里没有格子需要补。" }
        if gap == 0 {
            return "\(needed) 格需要补，库存还能补 \(capacity) 格 —— 直接用，不用买。"
        }
        return "\(needed) 格需要补，库存只够 \(capacity) 格，还差 \(gap) 格。"
    }
}
