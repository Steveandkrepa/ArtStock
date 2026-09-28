//
//  StockPlan.swift
//  ArtAssist — 美术生的工具箱
//
//  「库存与采购」的统一结论：把**颜料补充装**和**其他耗材**算成一句话。
//
//  ── 为什么要把两件事合起来 ───────────────────────────────────
//  真实反馈：「其他耗材也应该直接纳入库存与采购体系中啊」。
//
//  原来「其他耗材」是侧边栏一个独立分区，和「库存与采购」平级。
//  后果是：用户想知道"我该买什么"，得去两个地方各看一遍，
//  而且两边的结论各说各的 —— 一个说"建议买 3 个颜色"，
//  另一个说"2 项快用完了"，没有一处告诉你**总共要买什么**。
//
//  这恰恰是这个 App 最核心的承诺（不缺也不过多）该给出的答案。
//  所以现在两件事都进「库存与采购」，顶部一句话把两边合起来说。
//
//  ── 设计约束 ─────────────────────────────────────────────────
//  这个文件**只用 Foundation**，不 import SwiftData / SwiftUI。
//  `SupplyItem` 是 @Model，这里用 `SupplySnapshot` 承接它的值。
//  这样结论逻辑能在 macOS 上直接跑测试 —— "该不该买"这件事算错了，
//  用户就会重复购买或者漏买，而且他自己不会知道。
//

import Foundation

/// 一件耗材的取值快照。把 @Model 和纯逻辑隔开。
struct SupplySnapshot: Hashable, Sendable {
    var name: String
    var categoryName: String
    /// 分类的显式排序号。
    ///
    /// ⚠️ 不能只靠分类名排序 —— 中文的 `localizedStandardCompare` 结果
    /// 依赖当前 locale（拼音序、笔画序、日文汉字序都可能），
    /// 同一份数据在不同设备上顺序会不一样。用显式序号才是确定的。
    var categoryOrder: Int
    /// 当前数量。
    var quantity: Double
    var unit: String
    /// 低于这个数量就提醒补。0 表示不提醒。
    var lowThreshold: Double

    init(
        name: String,
        categoryName: String = "",
        categoryOrder: Int = 0,
        quantity: Double,
        unit: String = "个",
        lowThreshold: Double = 0
    ) {
        self.name = name
        self.categoryName = categoryName
        self.categoryOrder = categoryOrder
        self.quantity = quantity
        self.unit = unit
        self.lowThreshold = lowThreshold
    }
}

/// 一条"该补的耗材"。
struct SupplyRestockLine: Identifiable, Hashable, Sendable {
    var name: String
    var categoryName: String
    var quantityText: String
    /// 为什么该补。
    var reason: String

    var id: String { name }
}

// MARK: - 在途补充

/// 一件"正在路上"的补充。从包裹清单里提出来，只带纯值。
///
/// 为什么要有这个类型：采购结论必须**扣掉在途的量**，
/// 否则会重复下单 —— 那正好违背这个 App 的承诺（不缺也不过多）。
/// 用纯值而不是直接读 SwiftData 模型，是为了让"扣减"这件事能测。
struct IncomingSupply: Hashable, Sendable {
    /// true = 颜料补充装，false = 其他耗材。
    var isColor: Bool
    /// 颜色色号，或耗材名。
    var code: String
    /// 颜料补充装的类型。耗材为 nil。
    var refillKind: RefillKind?
    var quantity: Int
    /// 预计到达时间。nil = 还没设。
    var estimatedArrival: Date?
    /// 所属包裹的标识（用于界面上"来自哪个包裹"）。
    var packageID: String

    /// 能不能用来抵某个颜色的缺口。
    func coversColor(code targetCode: String, kind: RefillKind?) -> Bool {
        guard isColor, code == targetCode else { return false }
        // 类型没定（nil）时也算能抵 —— 用户还没说是挤出装还是替换装，
        // 但它确实是这个颜色的补充，不该被当成不存在。
        guard let kind else { return true }
        return refillKind == nil || refillKind == kind
    }

    func coversSupply(named name: String) -> Bool {
        !isColor && code == name
    }
}

/// 到货时间的说法。
///
/// 单独抽出来是因为"还有多久到"这种话最容易写得含糊：
/// "3 天"到底是含不含今天？已经过期了怎么讲？
/// 这些都得钉死，否则用户没法据它决定要不要现在下单。
enum ArrivalEstimate {

    /// 距离预计到达还有几天（按自然日，忽略时分）。
    ///
    /// - Returns: 0 = 今天，1 = 明天，负数 = 已超预计。
    static func daysUntil(_ arrival: Date, from now: Date, calendar: Calendar = .current) -> Int {
        let from = calendar.startOfDay(for: now)
        let to = calendar.startOfDay(for: arrival)
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// 一句话说明。
    ///
    /// - Parameter isStocked: 已经入库了就不再谈"还有几天到"。
    static func text(
        for arrival: Date?,
        from now: Date = .now,
        isReceived: Bool = false,
        calendar: Calendar = .current
    ) -> String {
        if isReceived { return "已收到" }
        guard let arrival else { return "到货时间未设" }
        let days = daysUntil(arrival, from: now, calendar: calendar)
        switch days {
        case ..<(-1): return "已超预计 \(-days) 天"
        case -1: return "预计昨天到"
        case 0: return "预计今天到"
        case 1: return "预计明天到"
        case 2...7: return "预计 \(days) 天后到"
        default: return "预计 \(days) 天后到（\(shortDate(arrival, calendar: calendar))）"
        }
    }

    private static func shortDate(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.month, .day], from: date)
        return "\(components.month ?? 0)/\(components.day ?? 0)"
    }

    /// 够不够格叫"历史"。
    ///
    /// 一次记录可能只是巧合，照它推算出来的仍然是编的 —— 所以至少要两次。
    static let minimumHistoryForEstimate = 2

    /// 从历史里学一个"这家快递一般几天到"。
    ///
    /// ⚠️ **不内置任何"顺丰 1 天、中通 3 天"这样的表。**
    ///    那种数据是我编的，而且各条线路差别很大 —— 编出来只会误导下单时机。
    ///
    /// - Parameter history: 这家快递过去几次的实际天数（只统计已入库包裹）。
    /// - Returns: 中位数天数；**样本不够就返回 nil，表示"估不出来"**。
    ///
    /// ── 为什么返回可选值 ─────────────────────────────────────
    /// 以前这里在样本不够时返回调用方给的兜底值（3 天），于是新建包裹时
    /// 会凭空得到一个"预计 3 天后到"。用户把一个**已经到货**的快递单号录进来，
    /// 界面就理直气壮地显示"3 天后到" —— 而那个 3 天没有任何依据。
    /// 编一个看起来确定的日期比说"不知道"更糟，所以这里改成 nil，
    /// 由界面老实显示"还没设"，让用户一键填。
    static func leadDays(history: [Int],
                         minimum: Int = minimumHistoryForEstimate) -> Int? {
        let valid = history.filter { $0 >= 0 && $0 <= 60 }.sorted()
        guard valid.count >= max(1, minimum) else { return nil }
        // 偶数个取中间两个的平均（四舍五入）
        let middle = valid.count / 2
        if valid.count % 2 == 1 { return valid[middle] }
        return Int(((Double(valid[middle - 1]) + Double(valid[middle])) / 2).rounded())
    }

    /// 一定要一个数字的版本（调用方自己承担"这是编的"这件事）。
    static func learnedLeadDays(history: [Int], fallback: Int = 3) -> Int {
        leadDays(history: history) ?? max(0, fallback)
    }
}

/// 一件耗材"还剩多少"的档位。
///
/// 为什么要分档而不是只显示数字：颜料盒那边一眼就能看出哪几格快空了，
/// 因为有余量条。耗材原来只有一个数字（"3 张"），没有"这是多还是少"的参照。
/// 分档之后卡片上就能画一条余量条、给一个颜色 —— 这才跟颜料盒是一套语言。
///
/// 档位的依据分两种情况：
///   · 用户设了「满量」→ 按比例分（最准，也是新加的字段）
///   · 没设满量      → 按提醒线分（退化到原来的逻辑，但至少有个档位）
enum SupplyLevel: String, CaseIterable, Sendable {
    /// 用完了。
    case out
    /// 快没了。
    case low
    /// 用掉一半左右。
    case half
    /// 够用。
    case okay
    /// 很充足。
    case plenty

    var displayName: String {
        switch self {
        case .out: return "用完了"
        case .low: return "快没了"
        case .half: return "剩一半"
        case .okay: return "够用"
        case .plenty: return "充足"
        }
    }

    /// 余量条应该画多满（0…1）。用于卡片上的视觉指示。
    var barFraction: Double {
        switch self {
        case .out: return 0
        case .low: return 0.15
        case .half: return 0.5
        case .okay: return 0.78
        case .plenty: return 1
        }
    }

    /// 是否该提醒补货。
    var needsAttention: Bool {
        self == .out || self == .low
    }
}

enum StockPlan {

    /// 算出一件耗材的余量档位。
    ///
    /// - Parameters:
    ///   - quantity: 当前数量。
    ///   - fullCapacity: 用户设的「满量」。0 或负数表示没设。
    ///   - lowThreshold: 提醒线。0 表示不提醒。
    static func level(
        quantity: Double,
        fullCapacity: Double,
        lowThreshold: Double
    ) -> SupplyLevel {
        if quantity <= 0 { return .out }

        if fullCapacity > 0 {
            let fraction = quantity / fullCapacity
            if fraction < 0.15 { return .low }
            if fraction < 0.5 { return .half }
            if fraction < 0.8 { return .okay }
            return .plenty
        }

        // 没设满量：只能靠提醒线。提醒线是"低于它就该补"，
        // 所以刚好在线上算 low，明显高于线算 okay。
        if lowThreshold > 0 {
            if quantity <= lowThreshold { return .low }
            if quantity <= lowThreshold * 2 { return .half }
            return .okay
        }

        // 什么都没设：只要还有就算够用。
        // 刻意不猜 —— 猜出来的"快没了"会让用户莫名其妙。
        return .okay
    }

    /// 余量比例。没设满量时返回 nil（没有参照就不能编一个比例出来）。
    static func remainingFraction(quantity: Double, fullCapacity: Double) -> Double? {
        guard fullCapacity > 0 else { return nil }
        return max(0, min(1, quantity / fullCapacity))
    }

    /// 用"在途"抵掉缺口。
    ///
    /// 这是整个采购结论里最要紧的一步：**已经在路上的量不该再买一次。**
    /// 不扣的话，用户看着"该买 2 支"又下了一单，回来一看抽屉里三支 ——
    /// 这个 App 的承诺（不缺也不过多）就破了。
    ///
    /// - Returns: 扣减后仍需购买的件数；被在途覆盖掉的件数；
    ///   以及**最早到货时间**（用来告诉用户"等等就到"还是"先买一支救急"）。
    static func netShortage(
        shortage: Int,
        incoming: [IncomingSupply],
        now: Date = .now
    ) -> (stillNeeded: Int, coveredBy: Int, earliestArrival: Date?) {
        guard shortage > 0 else { return (0, 0, nil) }
        let available = incoming.reduce(0) { $0 + max(0, $1.quantity) }
        let covered = min(shortage, available)
        let arrival = incoming.compactMap(\.estimatedArrival).min { lhs, rhs in
            ArrivalEstimate.daysUntil(lhs, from: now) < ArrivalEstimate.daysUntil(rhs, from: now)
        }
        return (max(0, shortage - covered), covered, arrival)
    }

    /// 这件耗材该不该补。
    ///
    /// 两种该补：已经用完（数量 ≤ 0），或者设了提醒线且掉到线下了。
    /// 没设提醒线（阈值 0）时只看"用完了没有" —— 尊重用户"别烦我"的选择。
    static func needsRestock(_ supply: SupplySnapshot) -> Bool {
        if supply.quantity <= 0 { return true }
        return supply.lowThreshold > 0 && supply.quantity <= supply.lowThreshold
    }

    /// 数量文案：整数不带小数点（"3 张"而不是"3.0 张"）。
    static func quantityText(_ supply: SupplySnapshot) -> String {
        let rounded = supply.quantity.rounded()
        let isWhole = abs(supply.quantity - rounded) < 0.0001
        let text: String
        if isWhole {
            text = String(Int(rounded))
        } else {
            text = String(format: "%.1f", supply.quantity)
        }
        return "\(text) \(supply.unit)"
    }

    /// 为什么该补，一句话。
    static func reason(for supply: SupplySnapshot) -> String {
        if supply.quantity <= 0 {
            return "已经用完了"
        }
        let remaining = quantityText(supply)
        if supply.lowThreshold > 0 {
            let threshold = String(format: "%g", supply.lowThreshold)
            return "只剩 \(remaining)，低于提醒线 \(threshold) \(supply.unit)"
        }
        return "只剩 \(remaining)"
    }

    /// 挑出所有该补的耗材，按分类序号再按名字排序。
    ///
    /// 排序是为了稳定：不排序的话每次进来顺序都在跳，用户会以为列表变了。
    /// 分类之间用**显式序号**（纸张 → 笔 → 橡皮 → 胶带 → 其他），
    /// 分类内按名字。
    static func restockLines(from supplies: [SupplySnapshot]) -> [SupplyRestockLine] {
        supplies
            .filter(needsRestock)
            .sorted { lhs, rhs in
                if lhs.categoryOrder != rhs.categoryOrder {
                    return lhs.categoryOrder < rhs.categoryOrder
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .map { supply in
                SupplyRestockLine(
                    name: supply.name,
                    categoryName: supply.categoryName,
                    quantityText: quantityText(supply),
                    reason: reason(for: supply)
                )
            }
    }

    /// 需要采购的耗材条数。
    static func restockCount(in supplies: [SupplySnapshot]) -> Int {
        supplies.filter(needsRestock).count
    }

    /// 统一结论：把颜料和耗材合起来说一句话。
    ///
    /// - Parameters:
    ///   - paintColors: 需要补货的颜色个数（来自 `PurchasePlan.suggestions`）。
    ///   - paintUnits: 这些颜色一共要买几件。
    ///   - supplies: 全部耗材。
    static func summary(
        paintColors: Int,
        paintUnits: Int,
        supplies: [SupplySnapshot]
    ) -> String {
        let supplyCount = restockCount(in: supplies)

        if paintColors == 0 && supplyCount == 0 {
            return "颜料和耗材都够用，暂时什么都不用买。"
        }

        var parts: [String] = []
        if paintColors > 0 {
            parts.append("颜料缺 \(paintColors) 个颜色（共 \(paintUnits) 件）")
        }
        if supplyCount > 0 {
            parts.append("耗材有 \(supplyCount) 项该补")
        }
        return "该买：" + parts.joined(separator: "；") + "。"
    }

    /// 两边都没有缺口。
    static func isEmpty(paintColors: Int, supplies: [SupplySnapshot]) -> Bool {
        paintColors == 0 && restockCount(in: supplies) == 0
    }
}
