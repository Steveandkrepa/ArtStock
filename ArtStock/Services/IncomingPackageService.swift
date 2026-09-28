//
//  IncomingPackageService.swift
//  ArtAssist — 美术生的工具箱
//
//  待收包裹的建立与入库。
//
//  ── 入库这一步是这个功能的落点 ───────────────────────────────
//  前面那一堆解析（订单文本、快递单号、商品匹配）如果最后不落到
//  "补充装库存 +2 支"上，就只是白看一遍。所以这里做的是：
//
//      包裹到货 → 点「入库」→
//        · 颜料补充装：找到那个颜色对应的库存记录，加上件数
//        · 耗材：找到那个耗材，加上数量
//        · 没匹配到的：**不猜**，让用户当场选或跳过
//
//  ⚠️ 刻意不做"数量对不上就自动改"这种事：实际到货可能少发、错发，
//     所以入库数量与"应该收到多少"分开记（`stockedQuantity` vs `quantity`），
//     用户能看出"这单少发了一支"。
//

import Foundation
import SwiftData

/// 一次入库的结果，用来给用户一句准确的反馈。
struct StockingOutcome {
    var stockedItems: Int = 0
    var skippedItems: Int = 0
    var refillUnitsAdded: Int = 0
    var supplyUnitsAdded: Double = 0
    var createdSupplies: [String] = []
    var messages: [String] = []

    var summary: String {
        if stockedItems == 0 { return "没有入库任何东西。" }
        var parts: [String] = []
        if refillUnitsAdded > 0 { parts.append("颜料补充装 \(refillUnitsAdded) 件") }
        if supplyUnitsAdded > 0 {
            parts.append("耗材 \(Fmt.number(supplyUnitsAdded)) 件")
        }
        var text = "已入库：" + parts.joined(separator: "、") + "。"
        if !createdSupplies.isEmpty {
            text += "新建了耗材：\(createdSupplies.joined(separator: "、"))。"
        }
        if skippedItems > 0 {
            text += "有 \(skippedItems) 条没入库（没匹配到或数量为 0）。"
        }
        return text
    }
}

/// ⚠️ 标 @MainActor：它调用的 `PaletteService` 是主线程隔离的
///（SwiftData + SwiftUI 的模型操作都在主线程做）。这个服务本身只被界面用，
/// 标上之后编译器不会再报"在主隔离上下文中同步调用"。
@MainActor
enum IncomingPackageService {

    // MARK: - 建立

    /// 把一次解析结果变成一条待收包裹。
    static func create(
        from parsed: ParsedOrderText,
        matched: [MatchedPackageItem],
        sourceRaw: String = "",
        taobaoOrderID: String = "",
        in context: ModelContext
    ) -> IncomingPackage {
        let inferred = parsed.trackingNumber.flatMap { TrackingNumberParser.inferCarrier($0) }
        let package = IncomingPackage(
            trackingNumber: parsed.trackingNumber ?? "",
            carrierName: parsed.carrier ?? inferred?.carrier ?? "",
            carrierIsGuess: (parsed.carrier == nil ? inferred?.confidence : .guess) != .certain,
            sourceRaw: sourceRaw,
            taobaoOrderID: taobaoOrderID,
            status: .inTransit
        )
        context.insert(package)

        // 顺手估一个到货时间（按你自己这家快递的历史）
        let estimate = estimateArrival(
            for: package.carrierName,
            createdFrom: package.orderedAt ?? package.createdAt,
            in: context
        )
        package.estimatedArrival = estimate.date
        package.arrivalSource = estimate.source

        for item in matched {
            let record = IncomingPackageItem(name: item.item.name, quantity: item.item.quantity)
            switch item.target {
            case .color(let code, _, let kind):
                record.targetKindRaw = "color"
                record.targetCode = code
                record.refillKind = kind
            case .supply(let name):
                record.targetKindRaw = "supply"
                record.targetCode = name
            case .unmatched:
                record.targetKindRaw = "unmatched"
            }
            record.package = package
            context.insert(record)
        }

        try? context.save()
        return package
    }

    /// 直接从一段文本建包裹（界面里"粘贴订单文本"和"扫面单"都走这里）。
    static func create(
        from text: String,
        catalog: PackageMatchCatalog,
        preferTracking: String? = nil,
        in context: ModelContext
    ) -> IncomingPackage {
        let parsed = OrderTextParser.parse(text, preferTracking: preferTracking)
        let matched = PackageItemMatcher.match(items: parsed.items, against: catalog)
        return create(from: parsed, matched: matched, sourceRaw: text, in: context)
    }

    // MARK: - 入库

    /// 把包裹里的条目写进库存。
    ///
    /// - Parameter onlyUnstocked: 只处理还没入库的条目（可以分次入库）。
    @discardableResult
    static func stock(
        _ package: IncomingPackage,
        onlyUnstocked: Bool = true,
        in context: ModelContext
    ) -> StockingOutcome {
        var outcome = StockingOutcome()

        for item in package.items {
            if onlyUnstocked, item.isStocked { continue }
            // 入库数量：用户可能改过（少发/错发）
            let amount = item.stockedQuantity > 0 ? item.stockedQuantity : item.quantity
            guard amount > 0 else {
                outcome.skippedItems += 1
                continue
            }

            switch item.targetKindRaw {
            case "color":
                guard let color = PaletteService.color(code: item.targetCode, in: context) else {
                    outcome.skippedItems += 1
                    outcome.messages.append("「\(item.name)」对应颜色 \(item.targetCode) 已不在颜色库里")
                    continue
                }
                guard let kind = item.refillKind else {
                    // 类型没定就不要瞎加 —— 加错地方比不加更糟
                    outcome.skippedItems += 1
                    outcome.messages.append("「\(item.name)」没指定是挤出装还是替换装，先选一下")
                    continue
                }
                addRefillUnits(amount, kind: kind, to: color, in: context)
                item.stockedQuantity = amount
                item.isStocked = true
                outcome.stockedItems += 1
                outcome.refillUnitsAdded += amount

            case "supply":
                if let supply = supplyItem(named: item.targetCode, in: context) {
                    supply.quantity += Double(amount)
                    supply.updatedAt = .now
                } else {
                    let created = SupplyItem(
                        name: item.targetCode,
                        quantity: Double(amount),
                        unit: "个"
                    )
                    context.insert(created)
                    outcome.createdSupplies.append(item.targetCode)
                }
                item.stockedQuantity = amount
                item.isStocked = true
                outcome.stockedItems += 1
                outcome.supplyUnitsAdded += Double(amount)

            default:
                outcome.skippedItems += 1
                outcome.messages.append("「\(item.name)」还没匹配到库里的东西")
            }
        }

        if package.items.allSatisfy({ $0.isStocked }) {
            package.status = .stocked
            package.stockedAt = .now
        }
        try? context.save()
        return outcome
    }

    /// 把一件补充装加进某个颜色的库存。
    ///
    /// 复用 `PaletteService.setStock`，所以"没开封整件"与"已开封剩余"的
    /// 区分是统一的 —— 到货的是**未开封整件**，所以只加 `units`。
    private static func addRefillUnits(
        _ amount: Int,
        kind: RefillKind,
        to color: PaintColor,
        in context: ModelContext
    ) {
        let existing = PaletteService.stock(for: color, kind: kind)
        let units = (existing?.units ?? 0) + amount
        PaletteService.setStock(
            units: units,
            capacityPerUnit: existing?.capacityPerUnit ?? kind.defaultCapacityPerUnit,
            partialCapacity: existing?.partialCapacity ?? 0,
            kind: kind,
            for: color,
            in: context
        )
        // 顺手记一条补充记录，便于回溯"这批是什么时候到的"
        let event = RefillEvent(
            kind: kind,
            colorCode: color.code,
            colorName: color.name,
            unitsUsed: 0,
            wellsFilled: 0,
            note: "到货入库 \(amount) \(kind.unitName)"
        )
        context.insert(event)
    }

    private static func supplyItem(named name: String, in context: ModelContext) -> SupplyItem? {
        let all = (try? context.fetch(FetchDescriptor<SupplyItem>())) ?? []
        let key = PaintLabelParser.nameKey(name)
        return all.first { PaintLabelParser.nameKey($0.name) == key }
            ?? all.first { PaintLabelParser.nameKey($0.name).contains(key) && !key.isEmpty }
    }

    // MARK: - 预计到达

    /// 默认的"一般几天到"。用户没历史时用它。
    ///
    /// 刻意是个**保守**的数（3 天）：估短了用户会以为该到了而焦虑，
    /// 估长了会影响"要不要现在下单"的判断。
    static let fallbackLeadDays = 3

    /// 新建包裹时顺手估一个到货时间。
    ///
    /// ── ⚠️ 没有历史就**不估**（返回 nil），这一点很重要 ─────────
    /// 这里原来在"这家快递没有历史"时直接编一个 `下单时间 + 3 天`。
    /// 结果：用户把一个**已经到货**的快递单号录进来（`下单时间` 就是刚才），
    /// 界面理直气壮地显示"预计 3 天后到" —— 而那个 3 天是我编的，
    /// 不是他的数据，也不是任何真实信息。
    ///
    /// 与其编一个看起来很确定的日期，不如老实说"还没设"，
    /// 让他一键填（旁边就有 1/2/3/7 天和一键入库）。
    ///
    /// - Returns: 有**你自己的**历史（至少两次已入库记录）才给日期，否则 nil。
    static func estimateArrival(
        for carrier: String,
        createdFrom orderedAt: Date,
        in context: ModelContext
    ) -> (date: Date?, source: ArrivalSource) {
        let history = leadDayHistory(for: carrier, in: context)
        // ⚠️ 估不出来就返回 nil —— **不要**在这里编一个默认天数。
        guard let days = ArrivalEstimate.leadDays(history: history) else {
            return (nil, .unknown)
        }
        let date = Calendar.current.date(byAdding: .day, value: days, to: orderedAt) ?? orderedAt
        return (date, .learned)
    }

    /// 这家快递过去几次"下单到收到"的实际天数。
    ///
    /// 只统计**已入库**的包裹（receivedAt 有值），因为那才是真实的到货时刻。
    static func leadDayHistory(for carrier: String, in context: ModelContext) -> [Int] {
        guard !carrier.isEmpty else { return [] }
        let all = (try? context.fetch(FetchDescriptor<IncomingPackage>())) ?? []
        let calendar = Calendar.current
        return all.compactMap { package in
            guard package.carrierName == carrier,
                  let received = package.receivedAt,
                  let ordered = package.orderedAt else { return nil }
            return calendar.dateComponents([.day], from: ordered, to: received).day
        }
    }

    /// 用户手动改到货时间。
    static func setArrival(_ date: Date?, for package: IncomingPackage, in context: ModelContext) {
        package.estimatedArrival = date
        package.arrivalSource = date == nil ? .unknown : .user
        try? context.save()
    }

    // MARK: - 在途量

    /// 把所有"还没入库"的包裹里的条目，提成纯值给采购结论用。
    ///
    /// 只取 `.inTransit` 与 `.received`（还没入库）—— 已入库的已经写进库存了，
    /// 再算一次就重复。
    static func incomingSupplies(in context: ModelContext) -> [IncomingSupply] {
        let all = (try? context.fetch(FetchDescriptor<IncomingPackage>())) ?? []
        var result: [IncomingSupply] = []
        for package in all where package.isRestocking {
            for item in package.items where !item.isStocked {
                let amount = item.stockedQuantity > 0 ? item.stockedQuantity : item.quantity
                guard amount > 0 else { continue }
                switch item.targetKindRaw {
                case "color":
                    result.append(IncomingSupply(
                        isColor: true,
                        code: item.targetCode,
                        refillKind: item.refillKind,
                        quantity: amount,
                        estimatedArrival: package.estimatedArrival,
                        packageID: package.trackingNumber.isEmpty
                            ? package.taobaoOrderID : package.trackingNumber
                    ))
                case "supply":
                    result.append(IncomingSupply(
                        isColor: false,
                        code: item.targetCode,
                        refillKind: nil,
                        quantity: amount,
                        estimatedArrival: package.estimatedArrival,
                        packageID: package.trackingNumber.isEmpty
                            ? package.taobaoOrderID : package.trackingNumber
                    ))
                default:
                    continue   // 没匹配到的条目不该影响采购结论
                }
            }
        }
        return result
    }

    /// 某个颜色的在途件数（界面上给格子打"在途"标记用）。
    static func incomingQuantity(
        forColor code: String,
        kind: RefillKind?,
        in context: ModelContext
    ) -> Int {
        incomingSupplies(in: context)
            .filter { $0.coversColor(code: code, kind: kind) }
            .reduce(0) { $0 + $1.quantity }
    }

    /// 某个耗材的在途数量。
    static func incomingQuantity(forSupply name: String, in context: ModelContext) -> Double {
        Double(incomingSupplies(in: context)
            .filter { $0.coversSupply(named: name) }
            .reduce(0) { $0 + $1.quantity })
    }

    // MARK: - 状态

    static func markReceived(_ package: IncomingPackage, in context: ModelContext) {
        package.status = .received
        package.receivedAt = .now
        try? context.save()
    }

    static func delete(_ package: IncomingPackage, in context: ModelContext) {
        context.delete(package)
        try? context.save()
    }

    /// 未入库的在途包裹数，用于侧边栏角标。
    static func pendingCount(in context: ModelContext) -> Int {
        let all = (try? context.fetch(FetchDescriptor<IncomingPackage>())) ?? []
        return all.filter { $0.status != .stocked }.count
    }

    /// 从数据库里取出匹配用的目录。
    static func catalog(in context: ModelContext) -> PackageMatchCatalog {
        let colors = PaletteService.allColors(in: context).map {
            PackageMatchCatalog.Color(code: $0.code, name: $0.name, ciCode: $0.ciCode)
        }
        let supplies = ((try? context.fetch(FetchDescriptor<SupplyItem>())) ?? []).map {
            PackageMatchCatalog.Supply(name: $0.name, unit: $0.unit)
        }
        // 颜色库还空着（用户没载入预设）时，至少用 42 色预设兜底，
        // 否则"群青补充装"会一条都匹配不上。
        var merged = colors
        if merged.isEmpty {
            merged = PackageMatchCatalog.presetOnly.colors
        }
        return PackageMatchCatalog(colors: merged, supplies: supplies)
    }
}
