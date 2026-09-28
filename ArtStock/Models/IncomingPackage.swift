//
//  IncomingPackage.swift
//  ArtAssist — 美术生的工具箱
//
//  待收包裹：买了什么、单号是什么、到货了没有、入了库没有。
//
//  ── 它解决的是哪一步 ─────────────────────────────────────────
//  用户说的是"输入补充耗材快递单号时，预先同步有哪些东西"。
//  拆开就是三件事，这个模型负责把它们串起来：
//
//      下单/发货 → 记下"这个单号里应该有什么"（items）
//      在途       → 显示它，心里有数（list）
//      到货       → 一键把清单加进补充装库存 / 耗材数量（stocked）
//
//  ⚠️ **迁移安全**：这两个是**新表**，加新表本身对已有数据是安全的
//     （additive）。但新表里的字段规则跟老表一样 ——
//     以后给它加字段时，仍然只能加 `T?` 或带默认值的。
//     `scripts/check-model-migration.py` 会盯着。
//

import Foundation
import SwiftData

/// 一条待收包裹。
@Model
final class IncomingPackage {

    /// 快递单号。可能为空（下单了但还没发货）。
    var trackingNumber: String

    /// 承运商名（本地推断或接口给的）。空表示认不出。
    var carrierName: String
    /// 承运商是不是**猜**的。界面据此提示"帮你猜的，可以改"。
    var carrierIsGuess: Bool

    /// 这一条的来源，便于溯源：粘贴的原文 / 淘宝订单号 / 手工录入。
    var sourceRaw: String
    /// 关联的淘宝订单号（从淘宝导入时有值）。
    var taobaoOrderID: String

    var statusRaw: String
    var note: String

    /// 下单/发货时间。用来学"这家快递一般几天到"。
    var orderedAt: Date?

    /// 预计到达时间。
    ///
    /// **默认由你的历史推算，也可以自己改。** 刻意不内置
    /// "顺丰 1 天、中通 3 天"这种表 —— 那种数据是编的，而且各条线路差别很大，
    /// 编出来只会误导下单时机（该等的时候买了，或该买的时候干等）。
    var estimatedArrival: Date?

    /// 到货时间是怎么来的：`user` 用户填的 / `learned` 按历史推算 / 空 = 没设。
    var arrivalSourceRaw: String = ""

    var createdAt: Date
    /// 用户点"已收到"的时间。
    var receivedAt: Date?
    /// 用户点"入库"的时间。
    var stockedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \IncomingPackageItem.package)
    var items: [IncomingPackageItem] = []

    init(
        trackingNumber: String = "",
        carrierName: String = "",
        carrierIsGuess: Bool = true,
        sourceRaw: String = "",
        taobaoOrderID: String = "",
        status: IncomingPackageStatus = .inTransit,
        note: String = "",
        orderedAt: Date? = nil,
        estimatedArrival: Date? = nil,
        arrivalSource: ArrivalSource = .unknown,
        createdAt: Date = .now
    ) {
        self.trackingNumber = trackingNumber
        self.carrierName = carrierName
        self.carrierIsGuess = carrierIsGuess
        self.sourceRaw = sourceRaw
        self.taobaoOrderID = taobaoOrderID
        self.statusRaw = status.rawValue
        self.note = note
        self.orderedAt = orderedAt ?? createdAt
        self.estimatedArrival = estimatedArrival
        self.arrivalSourceRaw = arrivalSource.rawValue
        self.createdAt = createdAt
    }
}

/// 预计到货时间是怎么来的。
///
/// 分开记是为了**界面上能说清可信度**：
/// 用户自己填的可以直接信，"按历史推算"的要标出来让他能改，
/// 没设的就要提示去设 —— 否则"还有几天到"这句话没有任何依据。
enum ArrivalSource: String, Sendable {
    /// 用户自己填的。
    case user
    /// 按他过去几次的实际天数推算的。
    case learned
    /// 没有历史，按默认天数估的（**不是**他的数据，界面要说清）。
    case fallback
    /// 还没设。
    case unknown

    var displayName: String {
        switch self {
        case .user: return "你填的"
        case .learned: return "按你的历史推算"
        case .fallback: return "按默认天数估的"
        case .unknown: return "未设置"
        }
    }
}

/// 包裹的状态。
enum IncomingPackageStatus: String, CaseIterable, Sendable {
    /// 在途 / 还没到。
    case inTransit
    /// 已收到，还没入库。
    case received
    /// 已入库。
    case stocked

    var displayName: String {
        switch self {
        case .inTransit: return "在途"
        case .received: return "已收到"
        case .stocked: return "已入库"
        }
    }

    var symbolName: String {
        switch self {
        case .inTransit: return "shippingbox"
        case .received: return "tray.and.arrow.down"
        case .stocked: return "checkmark.seal.fill"
        }
    }
}

/// 包裹里的一条。**记录"应该收到什么"，而不是"已经收到什么"** ——
// 实际到货可能少发、错发，所以入库时允许改数量。
@Model
final class IncomingPackageItem {

    /// 商品名（订单文本里的原名，保留便于核对）。
    var name: String
    /// 数量。
    var quantity: Int

    /// 匹配到的东西：`PackageItemTarget` 的编码形式。
    /// `color` / `supply` / `unmatched`
    var targetKindRaw: String
    /// 颜色色号或耗材名。`unmatched` 时为空。
    var targetCode: String
    /// 补充装类型：`squeeze` / `pan` / 空（不确定）。
    var refillKindRaw: String

    /// 入库时实际入了多少（可能跟 quantity 不同）。
    var stockedQuantity: Int
    var isStocked: Bool

    var package: IncomingPackage?

    init(
        name: String,
        quantity: Int,
        targetKindRaw: String = "unmatched",
        targetCode: String = "",
        refillKindRaw: String = "",
        stockedQuantity: Int = 0,
        isStocked: Bool = false
    ) {
        self.name = name
        self.quantity = max(1, quantity)
        self.targetKindRaw = targetKindRaw
        self.targetCode = targetCode
        self.refillKindRaw = refillKindRaw
        self.stockedQuantity = stockedQuantity
        self.isStocked = isStocked
    }
}

// MARK: - 桥接

extension IncomingPackage {

    var status: IncomingPackageStatus {
        get { IncomingPackageStatus(rawValue: statusRaw) ?? .inTransit }
        set { statusRaw = newValue.rawValue }
    }

    var arrivalSource: ArrivalSource {
        get { ArrivalSource(rawValue: arrivalSourceRaw) ?? .unknown }
        set { arrivalSourceRaw = newValue.rawValue }
    }

    /// 一句"还有多久到"。
    var arrivalText: String {
        ArrivalEstimate.text(
            for: estimatedArrival,
            isReceived: status != .inTransit
        )
    }

    /// 在途 / 已收到，但**还没入库** —— 也就是"正在补货中"。
    var isRestocking: Bool { status != .stocked }

    var orderedItems: [IncomingPackageItem] {
        items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 匹配上的条目数（入库前给用户一个预期）。
    var matchedCount: Int {
        items.filter { $0.targetKindRaw != "unmatched" }.count
    }

    var isReadyToStock: Bool {
        status == .received && !items.isEmpty && items.contains { !$0.isStocked }
    }

    /// 单号为空时的显示。
    var trackingDisplay: String {
        trackingNumber.isEmpty ? "还没填单号" : trackingNumber
    }

    /// 承运商显示（区分"猜的"）。
    var carrierDisplay: String {
        if carrierName.isEmpty { return "承运商未知" }
        return carrierIsGuess ? "\(carrierName)（推断）" : carrierName
    }

    /// 搜索/匹配用：单号 + 商品名拼起来。
    var searchText: String {
        ([trackingNumber, carrierName, note, taobaoOrderID] + items.map(\.name))
            .joined(separator: " ")
    }
}

extension IncomingPackageItem {

    var targetKind: String { targetKindRaw }

    var refillKind: RefillKind? {
        get { refillKindRaw.isEmpty ? nil : RefillKind(rawValue: refillKindRaw) }
        set { refillKindRaw = newValue?.rawValue ?? "" }
    }

    /// 界面上的"这条会入到哪"。
    var targetDisplay: String {
        switch targetKindRaw {
        case "color":
            let kindText = refillKind.map { "（\($0.displayName)）" } ?? "（类型未定）"
            return "→ 颜料补充装：\(targetCode)\(kindText)"
        case "supply":
            return "→ 耗材：\(targetCode)"
        default:
            return "→ 没匹配到，入库时新建"
        }
    }

    var matched: Bool { targetKindRaw != "unmatched" }
}
