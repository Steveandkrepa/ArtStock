//
//  PaintColor.swift
//  ArtAssist — 美术生的工具箱
//
//  颜色库：每种能在盒子里出现的颜色一条记录。
//  这是"扫码入库"的落点 —— 扫颜料包装上的码，解析出颜色信息，建成这里的一条。
//

import Foundation
import SwiftData

@Model
final class PaintColor {

    /// 色号。扫码拿到的业务主键，也是唯一标识。
    @Attribute(.unique) var code: String

    /// 色名，例如「群青」「镉红 中号」。
    var name: String

    var brand: String
    /// 系列 / 等级，例如「艺术家级」「学生级」。
    var series: String

    /// 显示用颜色值 `#RRGGBB`。扫不到时用户可以自己选一个。
    ///
    /// 说明：**颜料没有 RGB 的国际标准**。色名（"群青"）各国叫法不同，
    /// 屏幕显色和颜料在纸上的观感也隔着介质差异，所以这个值只求"看着像"。
    /// 真正有国际标准的是下面的 `ciCode`。
    var hex: String

    /// **Colour Index 国际颜料标准号**，例如 `PW6`（钛白）、`PB29`（群青）、`PR108`（大红）。
    ///
    /// 这是颜料行业真正通行的国际标准：它规定的是**化学成分**，全球唯一。
    /// 品牌自创色名（"马尔代夫""起司"）没有对应的标准号，为 nil。
    /// 可选属性，旧数据升级时 SwiftData 会自动补 nil，不需要迁移代码。
    var ciCode: String?

    /// 扫码时的原始内容，保留下来便于溯源。
    var scannedPayload: String

    var notes: String
    var createdAt: Date
    var updatedAt: Date

    /// 用户从实物上取过色的时间。nil = 还是内置/推断的色值。
    ///
    /// 用途很关键：内置的品牌自创色名（「马尔代夫」「起司」）本来就是猜的，
    /// 用户从实物采到的才是真的。所以「刷成标准值」必须**跳过**已校准的颜色，
    /// 否则一次误操作就把用户辛苦采的 42 个颜色全冲掉了。
    ///
    /// 用可选的 Date（而不是 Bool）有两个好处：旧数据升级时一定安全，
    /// 而且顺手记下了"什么时候采的"。
    var calibratedAt: Date?

    /// 哪些格子装着这个颜色。
    @Relationship(deleteRule: .nullify, inverse: \PaletteWell.color)
    var wells: [PaletteWell] = []

    /// 这个颜色有哪些补充装库存。
    @Relationship(deleteRule: .cascade, inverse: \RefillStock.color)
    var refills: [RefillStock] = []

    init(
        code: String,
        name: String,
        brand: String = "",
        series: String = "",
        hex: String = "",
        ciCode: String? = nil,
        scannedPayload: String = "",
        notes: String = "",
        calibratedAt: Date? = nil,
        createdAt: Date = .now
    ) {
        self.code = PaintColor.normalize(code)
        self.name = name
        self.brand = brand
        self.series = series
        self.hex = hex
        self.ciCode = ciCode?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        self.scannedPayload = scannedPayload
        self.notes = notes
        self.calibratedAt = calibratedAt
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

// MARK: - 规范化

extension PaintColor {

    /// 色号规范化：去空白、转大写，保证同一个码只对应一条记录。
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

// MARK: - 派生

extension PaintColor {

    /// 在盒子里占了几个格子。
    var wellCount: Int { wells.count }

    /// 色值是不是用户从实物上采的。
    var isCalibrated: Bool { calibratedAt != nil }

    /// 最紧张的那一格。用来决定"这个颜色要不要补"。
    var mostDepletedWell: PaletteWell? {
        wells.min { $0.level.rawValue < $1.level.rawValue }
    }

    /// 是否在盒子里至少有一格需要补充。
    var needsAttention: Bool {
        wells.contains { $0.level.needsRefill }
    }

    var subtitle: String {
        [brand, series].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: " · ")
    }

    /// 颜色名下面那行小字：品牌 · 系列 · 颜料标准号。
    var detailLine: String {
        var parts = [subtitle]
        if let ciCode, !ciCode.isBlank { parts.append(ciCode) }
        return parts.filter { !$0.isBlank }.joined(separator: " · ")
    }
}

// MARK: - 补充装库存

@Model
final class RefillStock {

    var kindRaw: String

    /// 还没开封的整支 / 整块数量。
    var units: Int

    /// 每个**整单位**能补几格。挤出补充装由用户填，直接替换装固定 1。
    var capacityPerUnit: Int

    /// 已经开封的那一支 / 那一块还剩几格可补。
    ///
    /// 这个字段是"不过多"的关键：挤出补充装软管一旦开封就用不满整支了，
    /// 若把它当作"整支可用"，库存会被高估，于是重复购买；
    /// 若直接丢弃，又会低估、漏买。单独记下来才准。
    var partialCapacity: Int

    /// 低于"还能补几次"这个值时提醒补货。
    var lowThresholdCapacity: Int

    var note: String
    var updatedAt: Date

    var color: PaintColor?

    init(
        kind: RefillKind,
        units: Int,
        capacityPerUnit: Int? = nil,
        partialCapacity: Int = 0,
        lowThresholdCapacity: Int = 2,
        note: String = "",
        updatedAt: Date = .now,
        color: PaintColor? = nil
    ) {
        self.kindRaw = kind.rawValue
        self.units = max(0, units)
        self.capacityPerUnit = max(1, capacityPerUnit ?? kind.defaultCapacityPerUnit)
        // 直接替换装的"半块"没有意义，强制归零。
        self.partialCapacity = kind == .pan ? 0 : max(0, min(partialCapacity, max(1, capacityPerUnit ?? 1)))
        self.lowThresholdCapacity = max(0, lowThresholdCapacity)
        self.note = note
        self.updatedAt = updatedAt
        self.color = color
    }
}

// MARK: - 枚举桥接与派生

extension RefillStock {

    var kind: RefillKind {
        get { RefillKind(rawValue: kindRaw) ?? .squeeze }
        set { kindRaw = newValue.rawValue }
    }

    /// 这一条库存还能补几格。**这是把两种补充装统一起来的关键指标。**
    ///
    /// 未开封的整单位 + 已开封那支的剩余量。
    var refillCapacity: Int {
        units * capacityPerUnit + partialCapacity
    }

    /// 是否已经不足以支撑一次补充。
    var isDepleted: Bool {
        refillCapacity <= 0
    }

    /// 是否低于提醒线。
    var isLow: Bool {
        refillCapacity <= lowThresholdCapacity
    }

    var capacityDescription: String {
        if kind == .pan {
            return "\(units) 个 · 还能补 \(refillCapacity) 格"
        }
        var text = "\(units) 支 × 每支补 \(capacityPerUnit) 格"
        if partialCapacity > 0 {
            text += " + 已开封剩 \(partialCapacity) 格"
        }
        return text + " · 还能补 \(refillCapacity) 格"
    }
}

// MARK: - 补充记录

/// 一次补充操作留下的记录。用于回溯"什么时候补的、消耗了什么"。
@Model
final class RefillEvent {

    var date: Date
    var kindRaw: String
    var colorCode: String
    var colorName: String
    /// 消耗了几个单位（支/个）。
    var unitsUsed: Int
    /// 一共补了几格。
    var wellsFilled: Int
    var note: String

    init(
        date: Date = .now,
        kind: RefillKind,
        colorCode: String,
        colorName: String,
        unitsUsed: Int,
        wellsFilled: Int,
        note: String = ""
    ) {
        self.date = date
        self.kindRaw = kind.rawValue
        self.colorCode = colorCode
        self.colorName = colorName
        self.unitsUsed = unitsUsed
        self.wellsFilled = wellsFilled
        self.note = note
    }

    var kind: RefillKind {
        get { RefillKind(rawValue: kindRaw) ?? .squeeze }
        set { kindRaw = newValue.rawValue }
    }

    var summary: String {
        if unitsUsed > 0 {
            return "用 \(unitsUsed) \(kind.unitName)\(kind.shortName)，补了 \(wellsFilled) 格"
        }
        return "补了 \(wellsFilled) 格"
    }
}
