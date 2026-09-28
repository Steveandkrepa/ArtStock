//
//  PreviewData.swift
//  ArtAssist — 美术生的工具箱
//
//  预览与首次启动的演示数据。
//
//  演示数据刻意做成**一盒正在使用中的颜料**：42 格装了大半，
//  有几格见底、有的颜色有补充装有的没有 —— 这样打开就能看到
//  「该补 / 该买 / 偏多」三种状态，而不用自己先录半天。
//

import Foundation
import SwiftData

#if DEBUG
@MainActor
enum PreviewData {

    /// 内存容器 + 演示数据。
    static let container: ModelContainer = {
        let container = try! ModelContainer(
            for: ArtStockStore.schema,
            configurations: [ArtStockStore.memoryConfiguration]
        )
        seed(into: container.mainContext)
        return container
    }()

    /// 只建库不填数据，用于测试空状态。
    static let emptyContainer: ModelContainer = {
        try! ModelContainer(
            for: ArtStockStore.schema,
            configurations: [ArtStockStore.memoryConfiguration]
        )
    }()

    // MARK: - 演示数据

    /// 演示用颜色：色号、色名、色值、品牌。
    private static let palette: [(String, String, String, String)] = [
        ("M-001", "钛白", "#F7F7F5", "马利"),
        ("M-002", "柠檬黄", "#FFF44F", "马利"),
        ("M-003", "土黄", "#C9A227", "马利"),
        ("M-004", "朱红", "#E34234", "马利"),
        ("M-005", "深红", "#8B1A1A", "马利"),
        ("M-006", "群青", "#2E5BFF", "温莎牛顿"),
        ("M-007", "湖蓝", "#2C9BC4", "马利"),
        ("M-008", "草绿", "#7BB661", "马利"),
        ("M-009", "深绿", "#1F6B3A", "马利"),
        ("M-010", "赭石", "#8B5A2B", "马利"),
        ("M-011", "熟褐", "#5C4033", "马利"),
        ("M-012", "象牙黑", "#1C1C1E", "马利"),
        ("M-013", "紫罗兰", "#7B4FA8", "温莎牛顿"),
        ("M-014", "粉红", "#E48FB0", "马利"),
        ("M-015", "橄榄绿", "#6B8E23", "马利"),
        ("M-016", "天蓝", "#6FB7E8", "马利"),
        ("M-017", "橙", "#F08030", "马利"),
        ("M-018", "灰色", "#8E8E93", "马利")
    ]

    static func seed(into context: ModelContext) {
        // ── 颜色库 ──
        var colors: [PaintColor] = []
        for (code, name, hex, brand) in palette {
            let color = PaintColor(code: code, name: name, brand: brand, hex: hex)
            context.insert(color)
            colors.append(color)
        }

        // ── 颜料盒：7×6 ──
        let box = PaletteBox(name: "我的颜料盒", rows: 7, columns: 6)
        context.insert(box)
        box.reconcileWells(in: context)

        // ── 把颜色按顺序装上格子，并给不同的余量，制造出真实的不均衡 ──
        let ordered = box.orderedWells
        let levels: [WellLevel] = [.full, .full, .high, .half, .low, .full]

        for (index, well) in ordered.enumerated() where index < colors.count {
            well.color = colors[index]
            well.level = levels[index % levels.count]
            well.lastRefilledAt = Date.now.addingTimeInterval(-Double(index % 7) * 86_400)
        }

        // ── 补充装库存：故意做出「够用 / 该买 / 偏多」三种状态 ──
        // 群青（第 6 格，low）：有库存 → 该补但别买
        if let c = colors.first(where: { $0.code == "M-006" }) {
            context.insert(RefillStock(kind: .squeeze, units: 1, capacityPerUnit: 3, color: c))
        }
        // 深红（第 5 格，low）：没库存 → 该买
        if let c = colors.first(where: { $0.code == "M-005" }) {
            _ = c  // 刻意不给它库存，用来演示"该买"
        }
        // 草绿（第 8 格，half）：库存很多但不缺 → 偏多
        if let c = colors.first(where: { $0.code == "M-008" }) {
            context.insert(RefillStock(kind: .squeeze, units: 4, capacityPerUnit: 3, color: c))
        }
        // 湖蓝（第 7 格，half）：一个直接替换装 → 演示两种补充装混用
        if let c = colors.first(where: { $0.code == "M-007" }) {
            context.insert(RefillStock(kind: .pan, units: 2, capacityPerUnit: 1, color: c))
        }

        // ── 其他耗材（其中两项故意低于提醒线）──
        let supplies: [(String, SupplyCategory, Double, String, Double)] = [
            ("4K 素描纸", .paper, 24, "张", 10),
            ("8K 水彩纸", .paper, 6, "张", 10),
            ("狼毫勾线笔 小", .brush, 2, "支", 1),
            ("猪鬃平头笔 8 号", .brush, 3, "支", 1),
            ("可塑橡皮", .eraser, 1, "块", 1),
            ("美纹纸胶带", .tape, 2, "卷", 1)
        ]
        for (name, category, quantity, unit, threshold) in supplies {
            context.insert(SupplyItem(name: name, category: category, quantity: quantity,
                                      unit: unit, lowThreshold: threshold))
        }

        // ── 一条补充记录，让历史不是空的 ──
        context.insert(RefillEvent(
            kind: .squeeze,
            colorCode: "M-006",
            colorName: "群青",
            unitsUsed: 1,
            wellsFilled: 2,
            note: "演示数据"
        ))

        try? context.save()
    }
}
#endif
