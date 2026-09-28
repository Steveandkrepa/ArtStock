//
//  PaletteService.swift
//  ArtAssist — 美术生的工具箱
//
//  把「盒子里的存量」和「抽屉里的库存」对上，算出该不该补、补不补得起、
//  要不要买、买多少才不过多。
//
//  ⚠️ 所有**算术**都在 RefillMath.swift 里（纯函数、有测试覆盖）。
//     本文件只负责把它们和 SwiftData 对象、ModelContext 接起来。
//     不要把判定逻辑再抄一遍到这里 —— 抄一遍就等于失去测试保护。
//

import Foundation
import SwiftData

// MARK: - 颜色库存状态

/// 某个颜色在当前盒子与库存下的处境。
struct ColorStockStatus: Identifiable {

    var color: PaintColor
    var wellsNeedingRefill: [PaletteWell]
    var squeezeCapacity: Int
    var panCapacity: Int
    var needed: Int
    var shortage: Int
    var state: ColorStockState

    var id: String { color.code }

    var totalCapacity: Int { squeezeCapacity + panCapacity }

    /// 一句话结论，直接显示在界面上。
    var headline: String {
        switch state {
        case .unassigned: return "还没装进盒子"
        case .fine: return "够用"
        case .canRefill: return "该补 \(needed) 格 · 抽屉里有货"
        case .mustBuy: return "缺 \(shortage) 格 · 需要补货"
        case .overstocked: return "库存偏多"
        }
    }

    /// 展开说明，讲清楚为什么。
    var detail: String {
        switch state {
        case .unassigned:
            return "把颜色分配到格子里后，这里会显示它的存量情况。"
        case .fine:
            return "盒子里没有格子需要补。还能补 \(totalCapacity) 格。"
        case .canRefill, .mustBuy:
            return RefillMath.shortfallExplanation(needed: needed, capacity: totalCapacity)
        case .overstocked:
            return "没有格子需要补，但库存还能补 \(totalCapacity) 格，明显超出用量。先别买。"
        }
    }

    /// 是否需要用户行动。
    var isActionable: Bool {
        state == .mustBuy || state == .canRefill
    }
}

// MARK: - 购买建议

struct PurchaseSuggestion: Identifiable {
    var color: PaintColor
    var kind: RefillKind
    var units: Int
    var reason: String
    /// 这个颜色在途的补充件数。
    var incomingUnits: Int = 0
    /// 在途预计到达的一句话（"预计明天到"）。
    var incomingArrivalText: String?
    /// 缺口是不是被在途完全覆盖了（units == 0 且有在途）。
    var coveredByIncoming: Bool { incomingUnits > 0 && units == 0 }

    var id: String { "\(color.code)-\(kind.rawValue)" }
}

struct PurchasePlan {
    var suggestions: [PurchaseSuggestion]
    /// 被判定为"库存过多、别再买"的颜色。
    var overstockedColors: [PaintColor]

    /// 有没有"真的需要买"的（在途已覆盖的不算）。
    var isEmpty: Bool { !suggestions.contains { $0.units > 0 } }
    var totalUnits: Int { suggestions.reduce(0) { $0 + $1.units } }
    /// 有几个颜色的缺口被在途覆盖了。
    var coveredCount: Int { suggestions.filter(\.coveredByIncoming).count }

    var summary: String {
        if suggestions.isEmpty {
            return overstockedColors.isEmpty
                ? "暂时什么都不用买。"
                : "没有缺口，而且有 \(overstockedColors.count) 个颜色库存偏多 —— 先别买。"
        }
        let buying = suggestions.filter { $0.units > 0 }
        if buying.isEmpty {
            return "缺口都被在途的补充装覆盖了，先别买。"
        }
        var text = "建议买 \(buying.count) 个颜色、共 \(totalUnits) 件。"
        if coveredCount > 0 {
            text += "另有 \(coveredCount) 个颜色在途已覆盖，不用买。"
        }
        return text
    }
}

// MARK: - 补充结果

struct RefillOutcome {
    var wellsFilled: Int
    var unitsUsed: Int
    var remainingCapacity: Int
    var wasShort: Bool

    var message: String {
        if wellsFilled == 0 {
            return "库存不足，没能补充任何格子。"
        }
        var text = "补了 \(wellsFilled) 格"
        if unitsUsed > 0 { text += "，用掉 \(unitsUsed) 件" }
        if wasShort {
            text += "。库存不够全部补完，剩下的格子还空着。"
        } else {
            text += "。"
        }
        text += "这条库存还能补 \(remainingCapacity) 格。"
        return text
    }
}

// MARK: - 服务

@MainActor
enum PaletteService {

    // MARK: - 盒子

    /// 取当前盒子；没有就按默认尺寸建一个并补齐格子。
    ///
    /// 个人使用只有一盒，所以不做多盒管理，取第一条即可。
    static func loadOrCreateBox(
        in context: ModelContext,
        rows: Int = 7,
        columns: Int = 6
    ) -> PaletteBox {
        let descriptor = FetchDescriptor<PaletteBox>(
            sortBy: [SortDescriptor(\PaletteBox.createdAt)]
        )
        if let existing = try? context.fetch(descriptor).first {
            // 顺手补齐：用户可能改过尺寸，或上次建库中途退出了。
            existing.reconcileWells(in: context)
            try? context.save()
            return existing
        }

        let box = PaletteBox(rows: rows, columns: columns)
        context.insert(box)
        box.reconcileWells(in: context)
        try? context.save()
        return box
    }

    /// 改盒子尺寸并补齐/裁剪格子。
    static func resize(_ box: PaletteBox, rows: Int, columns: Int, in context: ModelContext) {
        box.rows = max(1, rows)
        box.columns = max(1, columns)
        box.reconcileWells(in: context)
        box.updatedAt = .now
        try? context.save()
    }

    // MARK: - 格子

    static func setLevel(_ level: WellLevel, for well: PaletteWell, in context: ModelContext) {
        well.level = level
        try? context.save()
    }

    /// 给格子分配颜色（传 nil 表示清空这一格）。
    static func assign(_ color: PaintColor?, to well: PaletteWell, in context: ModelContext) {
        well.color = color
        // 刚装上颜色的格子若还标着"空"，顺手置为满 —— 否则会立刻被算成需要补充。
        if color != nil, well.level == .empty {
            well.level = .full
            well.lastRefilledAt = .now
        }
        if color == nil {
            well.level = .empty
            well.lastRefilledAt = nil
        }
        try? context.save()
    }

    /// 交换两格的**内容**。
    ///
    /// ⚠️ 交换的是格子里的东西（颜色、余量、上次补充时间、备注），
    ///    不是格子本身 —— **格子代表物理位置，位置不能动**。
    ///    用户把两格颜料对调时想要的就是这个效果。
    ///
    /// 余量必须跟着颜色一起走：只换颜色不换余量的话，
    /// 「满的群青」和「快没了的湖蓝」对调后会变成「满的湖蓝」+「快没了的群青」，
    /// 跟实物完全对不上。
    static func swapWells(_ a: PaletteWell, _ b: PaletteWell, in context: ModelContext) {
        guard a.persistentModelID != b.persistentModelID else { return }

        let aColor = a.color
        let aLevel = a.level
        let aRefilled = a.lastRefilledAt
        let aNote = a.note

        a.color = b.color
        a.level = b.level
        a.lastRefilledAt = b.lastRefilledAt
        a.note = b.note

        b.color = aColor
        b.level = aLevel
        b.lastRefilledAt = aRefilled
        b.note = aNote

        a.box?.updatedAt = .now
        try? context.save()
    }

    static func markRefilled(_ well: PaletteWell, in context: ModelContext) {
        well.level = .afterRefill
        well.lastRefilledAt = .now
        try? context.save()
    }

    // MARK: - 补充（消耗库存）

    /// 用一条库存去补若干格子。
    ///
    /// 消耗顺序（先用已开封、再开新的）由 `RefillMath.consume` 决定并有测试覆盖，
    /// 这里只做写回。
    @discardableResult
    static func refill(
        wells: [PaletteWell],
        using stock: RefillStock,
        in context: ModelContext
    ) -> RefillOutcome {

        let targets = wells.filter { $0.level.needsRefill }
        guard !targets.isEmpty else {
            return RefillOutcome(wellsFilled: 0, unitsUsed: 0,
                                 remainingCapacity: stock.refillCapacity, wasShort: false)
        }

        let result = RefillMath.consume(
            needed: targets.count,
            units: stock.units,
            capacityPerUnit: stock.capacityPerUnit,
            partial: stock.partialCapacity
        )

        guard result.filled > 0 else {
            return RefillOutcome(wellsFilled: 0, unitsUsed: 0,
                                 remainingCapacity: stock.refillCapacity, wasShort: true)
        }

        // 写回库存
        stock.units = max(0, stock.units - result.unitsUsed)
        stock.partialCapacity = stock.kind == .pan ? 0 : result.remainingPartial
        stock.updatedAt = .now

        // 只把真正补上的格子置满，不够的保持原样（不能假装补过了）
        for well in targets.prefix(result.filled) {
            well.level = .afterRefill
            well.lastRefilledAt = .now
        }

        let event = RefillEvent(
            kind: stock.kind,
            colorCode: stock.color?.code ?? "",
            colorName: stock.color?.name ?? "",
            unitsUsed: result.unitsUsed,
            wellsFilled: result.filled
        )
        context.insert(event)

        try? context.save()

        return RefillOutcome(
            wellsFilled: result.filled,
            unitsUsed: result.unitsUsed,
            remainingCapacity: stock.refillCapacity,
            wasShort: result.wasShort
        )
    }

    /// 用某个颜色现有的库存去补它的所有待补格子。
    /// - Returns: 没有任何可用库存时返回 nil。
    static func refillAll(for color: PaintColor, in context: ModelContext) -> RefillOutcome? {
        let targets = color.wells.filter { $0.level.needsRefill }
        guard !targets.isEmpty else { return nil }

        // 优先用挤出补充装（单位容量更大），没有可用库存再用直接替换装。
        let ordered = color.refills.sorted { lhs, rhs in
            if lhs.kind == rhs.kind { return lhs.refillCapacity > rhs.refillCapacity }
            return lhs.kind == .squeeze
        }
        guard let stock = ordered.first(where: { $0.refillCapacity > 0 }) else { return nil }

        return refill(wells: targets, using: stock, in: context)
    }

    // MARK: - 状态判定

    /// 算出一个颜色的处境。判定交给 RefillMath。
    static func status(for color: PaintColor) -> ColorStockStatus {
        let needing = color.wells
            .filter { $0.level.needsRefill }
            .sorted { $0.level.rawValue < $1.level.rawValue }

        let squeeze = color.refills.first { $0.kind == .squeeze }?.refillCapacity ?? 0
        let pan = color.refills.first { $0.kind == .pan }?.refillCapacity ?? 0
        let total = squeeze + pan
        let needed = needing.count

        return ColorStockStatus(
            color: color,
            wellsNeedingRefill: needing,
            squeezeCapacity: squeeze,
            panCapacity: pan,
            needed: needed,
            shortage: RefillMath.shortage(needed: needed, capacity: total),
            state: RefillMath.state(needed: needed, capacity: total, isAssigned: !color.wells.isEmpty)
        )
    }

    static func statuses(for colors: [PaintColor]) -> [ColorStockStatus] {
        colors.map { status(for: $0) }
            .sorted { lhs, rhs in
                rank(lhs.state) == rank(rhs.state)
                    ? lhs.color.name.localizedStandardCompare(rhs.color.name) == .orderedAscending
                    : rank(lhs.state) < rank(rhs.state)
            }
    }

    private static func rank(_ state: ColorStockState) -> Int {
        switch state {
        case .mustBuy: return 0
        case .canRefill: return 1
        case .overstocked: return 2
        case .fine: return 3
        case .unassigned: return 4
        }
    }

    // MARK: - 购买计划

    /// 汇总该买什么、买多少。核心目标：**不缺，也不过多**。
    static func purchasePlan(
        for colors: [PaintColor],
        incoming: [IncomingSupply] = []
    ) -> PurchasePlan {
        var suggestions: [PurchaseSuggestion] = []
        var overstocked: [PaintColor] = []

        for color in colors {
            let status = status(for: color)
            guard status.shortage > 0 else {
                if status.state == .overstocked { overstocked.append(color) }
                continue
            }

            // 补货类型：优先沿用这个颜色已有的类型；都没有就用挤出补充装。
            let hasSqueeze = color.refills.contains { $0.kind == .squeeze }
            let hasPan = color.refills.contains { $0.kind == .pan }
            let kind: RefillKind = hasSqueeze ? .squeeze : (hasPan ? .pan : .squeeze)

            let perUnit = kind == .pan
                ? 1
                : (color.refills.first { $0.kind == .squeeze }?.capacityPerUnit
                   ?? RefillKind.squeeze.defaultCapacityPerUnit)

            // ⚠️ **扣在途**：已经在路上的补充装不该再买一次。
            //    缺的是"格"，在途的是"件"，先换算（件 × 每件补几格）。
            let transit = incoming.filter { $0.coversColor(code: color.code, kind: kind) }
            let transitUnits = transit.reduce(0) { $0 + max(0, $1.quantity) }
            let effectiveShortage = max(0, status.shortage - transitUnits * perUnit)
            let units = RefillMath.unitsToBuy(
                shortage: effectiveShortage, capacityPerUnit: perUnit
            )

            let arrivalText = transit.compactMap(\.estimatedArrival)
                .min()
                .map { ArrivalEstimate.text(for: $0) }

            let reason: String
            if transitUnits > 0, units == 0 {
                reason = "缺 \(status.shortage) 格，在途 \(transitUnits) 件已覆盖（\(arrivalText ?? "待确认")）"
            } else if transitUnits > 0 {
                reason = "缺 \(status.shortage) 格（在途 \(transitUnits) 件已抵掉一部分），\(kind.shortName)每件补 \(perUnit) 格"
            } else {
                reason = "缺 \(status.shortage) 格，\(kind.shortName)\(kind.unitName)每件补 \(perUnit) 格"
            }

            suggestions.append(PurchaseSuggestion(
                color: color,
                kind: kind,
                units: units,
                reason: reason,
                incomingUnits: transitUnits,
                incomingArrivalText: arrivalText
            ))
        }

        suggestions.sort { $0.color.name.localizedStandardCompare($1.color.name) == .orderedAscending }

        return PurchasePlan(suggestions: suggestions, overstockedColors: overstocked)
    }

    // MARK: - 预设色卡

    /// 载入 42 色水粉预设：建颜色库条目，并按实物排布顺序填进盒子。
    ///
    /// - Parameter overwrite: true 时连已有颜色的格子也一起替换。
    ///   false（默认）只填空格子 —— 用户已经装好的颜色不该被悄悄冲掉。
    /// - Returns: 新建了几个颜色、填了几格。
    @discardableResult
    static func loadPresetColors(
        into box: PaletteBox,
        overwrite: Bool = false,
        in context: ModelContext
    ) -> (colorsCreated: Int, wellsFilled: Int) {

        var created = 0
        var presetColors: [PaintColor] = []

        for preset in PresetColors.standard42 {
            let code = PresetColors.code(forIndex: preset.index)
            let existed = color(code: code, in: context) != nil
            let paint = upsertColor(
                code: code,
                name: preset.name,
                series: PresetColors.standard42Name,
                hex: preset.hex,
                ciCode: preset.ciCode,
                in: context
            )
            if !existed { created += 1 }
            presetColors.append(paint)
        }

        var filled = 0
        let wells = box.orderedWells
        for (offset, well) in wells.enumerated() where offset < presetColors.count {
            if well.color != nil && !overwrite { continue }
            well.color = presetColors[offset]
            // 刚装上的格子按"满"起步，否则会立刻被算成需要补充。
            if well.level == .empty {
                well.level = .full
                well.lastRefilledAt = .now
            }
            filled += 1
        }

        box.updatedAt = .now
        try? context.save()
        return (created, filled)
    }

    /// 把颜色库里所有预设色卡的色值刷新成当前的标准数据。
    ///
    /// 用途：老版本装过预设、色值是按印象填的，升级后一键换成标准值。
    /// 只动预设色（色号 `PRESET-xx`），用户自己建的颜色和改过的名字不会被动。
    @discardableResult
    static func refreshPresetColors(in context: ModelContext) -> Int {
        var updated = 0
        for preset in PresetColors.standard42 {
            guard let paint = color(code: PresetColors.code(forIndex: preset.index), in: context) else { continue }
            // ⚠️ 已校准的颜色**绝对不覆盖**。
            //    内置的品牌自创色名（马尔代夫、起司…）本来就是猜的，
            //    用户从实物采到的才是真的。这里要是覆盖了，
            //    一次误点就把人家辛苦采的 42 个颜色全冲成错的。
            guard !paint.isCalibrated else { continue }

            var touched = false
            // 色名被用户改过就不动色值 —— 改名的意思往往就是"这个格子我换了别的颜料"。
            if paint.name == preset.name, paint.hex.uppercased() != preset.hex.uppercased() {
                paint.hex = preset.hex
                touched = true
            }
            // 标准号是客观事实，不管名字改没改都补上。
            if let ci = preset.ciCode, paint.ciCode != ci {
                paint.ciCode = ci
                touched = true
            }
            if touched {
                paint.updatedAt = .now
                updated += 1
            }
        }
        try? context.save()
        return updated
    }

    /// 盒子当前是否已经完全按预设色卡装好。
    static func isPresetLoaded(into box: PaletteBox, in context: ModelContext) -> Bool {
        let wells = box.orderedWells
        guard wells.count >= PresetColors.standard42.count else { return false }
        for (offset, preset) in PresetColors.standard42.enumerated() {
            guard wells[offset].color?.code == PresetColors.code(forIndex: preset.index) else {
                return false
            }
        }
        return true
    }

    // MARK: - 定位格子

    /// 这个颜色现在装在哪个格子里（没有就返回 nil）。
    ///
    /// 认字入库时用它做"这个颜色你已经有了，在第几格"的提示 ——
    /// 有了位置，用户就不用自己去 42 格里找。
    static func wellHolding(_ color: PaintColor, in context: ModelContext) -> PaletteWell? {
        let boxes = (try? context.fetch(FetchDescriptor<PaletteBox>())) ?? []
        for box in boxes {
            if let well = box.orderedWells.first(where: { $0.color?.code == color.code }) {
                return well
            }
        }
        return nil
    }

    /// 盒子里第一个空格子。
    static func firstEmptyWell(in context: ModelContext) -> PaletteWell? {
        let boxes = (try? context.fetch(FetchDescriptor<PaletteBox>())) ?? []
        return boxes.first?.orderedWells.first { $0.color == nil }
    }

    // MARK: - 颜色库

    static func color(code: String, in context: ModelContext) -> PaintColor? {
        let key = PaintColor.normalize(code)
        guard !key.isEmpty else { return nil }
        var descriptor = FetchDescriptor<PaintColor>(
            predicate: #Predicate<PaintColor> { $0.code == key }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func allColors(in context: ModelContext) -> [PaintColor] {
        let descriptor = FetchDescriptor<PaintColor>(
            sortBy: [SortDescriptor(\PaintColor.name, comparator: .localizedStandard)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 扫码入库：已有同色号就更新，没有就新建。
    ///
    /// 用"更新而不是重复插入"，是因为同一支颜料可能被反复扫到 ——
    /// 每次都新建会让颜色库迅速被重复项塞满。
    @discardableResult
    static func upsertColor(
        code: String,
        name: String,
        brand: String = "",
        series: String = "",
        hex: String = "",
        ciCode: String? = nil,
        scannedPayload: String = "",
        in context: ModelContext
    ) -> PaintColor {
        if let existing = color(code: code, in: context) {
            if !name.isEmpty { existing.name = name }
            if !brand.isEmpty { existing.brand = brand }
            if !series.isEmpty { existing.series = series }
            if !hex.isEmpty { existing.hex = hex }
            if let ciCode, !ciCode.isBlank { existing.ciCode = ciCode }
            if !scannedPayload.isEmpty { existing.scannedPayload = scannedPayload }
            existing.updatedAt = .now
            try? context.save()
            return existing
        }

        let created = PaintColor(
            code: code,
            name: name.isEmpty ? code : name,
            brand: brand,
            series: series,
            hex: hex,
            ciCode: ciCode,
            scannedPayload: scannedPayload
        )
        context.insert(created)
        try? context.save()
        return created
    }

    /// 删除颜色。格子的引用会按 nullify 解除，格子本身保留（变回空格）。
    static func delete(_ color: PaintColor, in context: ModelContext) {
        context.delete(color)
        try? context.save()
    }

    // MARK: - 库存维护

    static func stock(for color: PaintColor, kind: RefillKind) -> RefillStock? {
        color.refills.first { $0.kind == kind }
    }

    /// 设置某颜色某类型的库存；不存在就创建。
    @discardableResult
    static func setStock(
        units: Int,
        capacityPerUnit: Int,
        partialCapacity: Int = 0,
        kind: RefillKind,
        for color: PaintColor,
        in context: ModelContext
    ) -> RefillStock {
        if let existing = stock(for: color, kind: kind) {
            existing.units = max(0, units)
            existing.capacityPerUnit = max(1, capacityPerUnit)
            existing.partialCapacity = kind == .pan ? 0 : max(0, partialCapacity)
            existing.updatedAt = .now
            try? context.save()
            return existing
        }

        let created = RefillStock(
            kind: kind,
            units: units,
            capacityPerUnit: capacityPerUnit,
            partialCapacity: partialCapacity,
            color: color
        )
        context.insert(created)
        try? context.save()
        return created
    }

    static func adjustStock(_ stock: RefillStock, by delta: Int, in context: ModelContext) {
        stock.units = max(0, stock.units + delta)
        stock.updatedAt = .now
        try? context.save()
    }

    static func recentRefillEvents(in context: ModelContext, limit: Int = 50) -> [RefillEvent] {
        var descriptor = FetchDescriptor<RefillEvent>(
            sortBy: [SortDescriptor(\RefillEvent.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }
}
