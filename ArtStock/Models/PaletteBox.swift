//
//  PaletteBox.swift
//  ArtAssist — 美术生的工具箱
//
//  颜料盒本体：7×6 = 42 格。
//
//  设计取向：面向**个人美术生自己的一盒颜料**，不是库房。
//  所以没有供应商、单价、库存价值、操作人这些东西 —— 那些是仓库软件的语言。
//  这里只有：哪一格装的什么颜色、还剩多少。
//

import Foundation
import SwiftData

// MARK: - 余量档位

/// 格子里的颜料还剩多少。
///
/// 刻意用**五档目测**而不是精确百分比：站在画桌前看一眼就能判断，
/// 而输入一个"37%"既不现实也不需要 —— 知道"快见底了"就够了。
enum WellLevel: Int, CaseIterable, Codable, Identifiable, Sendable {
    case empty = 0
    case low = 1
    case half = 2
    case high = 3
    case full = 4

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .empty: return "空了"
        case .low: return "快没了"
        case .half: return "一半"
        case .high: return "七成"
        case .full: return "满的"
        }
    }

    /// 用于在网格里画余量指示条。
    var fill: Double {
        switch self {
        case .empty: return 0
        case .low: return 0.2
        case .half: return 0.5
        case .high: return 0.75
        case .full: return 1.0
        }
    }

    var symbolName: String {
        switch self {
        case .empty: return "circle.dashed"
        case .low: return "exclamationmark.circle.fill"
        case .half: return "circle.lefthalf.filled"
        case .high: return "circle.bottomrighthalf.pattern.checkered"
        case .full: return "circle.fill"
        }
    }

    /// 是否需要补充。这是"要不要动库存"的判定线。
    var needsRefill: Bool {
        self == .empty || self == .low
    }

    /// 颜色标记：越紧急越红。
    var isUrgent: Bool {
        self == .empty
    }

    /// 从满格补充后回到的档位。
    static let afterRefill: WellLevel = .full
}

// MARK: - 格子位置

/// 一格在盒子里的位置。行列都用 1 开始，方便和实物对照。
struct WellPosition: Hashable, Codable, Sendable {
    var row: Int
    var column: Int

    /// 展示用标签：列用字母、行用数字，跟棋盘/表格的直觉一致（A1、C4）。
    var label: String {
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let index = max(0, min(column - 1, letters.count - 1))
        let letter = String(Array(letters)[index])
        return "\(letter)\(row)"
    }
}

// MARK: - 颜料盒

@Model
final class PaletteBox {

    var name: String
    var rows: Int
    var columns: Int
    var createdAt: Date
    var updatedAt: Date
    var note: String

    @Relationship(deleteRule: .cascade, inverse: \PaletteWell.box)
    var wells: [PaletteWell] = []

    init(
        name: String = "我的颜料盒",
        rows: Int = 7,
        columns: Int = 6,
        createdAt: Date = .now,
        note: String = ""
    ) {
        self.name = name
        self.rows = max(1, rows)
        self.columns = max(1, columns)
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.note = note
    }
}

// MARK: - 派生

extension PaletteBox {

    var totalWells: Int { rows * columns }

    /// 按行列顺序排好的格子。SwiftData 关系是无序的，展示前必须自己排。
    var orderedWells: [PaletteWell] {
        wells.sorted {
            $0.row == $1.row ? $0.column < $1.column : $0.row < $1.row
        }
    }

    /// 某个位置的格子。
    func well(at position: WellPosition) -> PaletteWell? {
        wells.first { $0.row == position.row && $0.column == position.column }
    }

    /// 是否每个位置都有对应的格子对象。
    var isFullyPopulated: Bool {
        wells.count == totalWells
    }

    /// 还没装颜色的格子数。
    var emptySlotCount: Int {
        wells.filter { $0.color == nil }.count
    }

    /// 已经装了颜色的格子数。
    var assignedWellCount: Int {
        wells.filter { $0.color != nil }.count
    }

    /// 需要补充的格子。
    var wellsNeedingRefill: [PaletteWell] {
        wells.filter { $0.color != nil && $0.level.needsRefill }
            .sorted { $0.level.rawValue < $1.level.rawValue }
    }

    /// 用当前行列数补齐缺失的格子。
    ///
    /// 用户可能中途改了盒子尺寸（比如从 24 格换成 42 格），
    /// 这时需要把多出来的位置补上、把越界的格子删掉。
    /// - Returns: 是否发生了改动。
    @discardableResult
    func reconcileWells(in context: ModelContext) -> Bool {
        var changed = false

        // 1) 删掉越界的格子
        for well in wells where well.row > rows || well.column > columns || well.row < 1 || well.column < 1 {
            context.delete(well)
            changed = true
        }

        // 2) 补齐缺失的位置
        let existing = Set(wells.map { WellPosition(row: $0.row, column: $0.column) })
        for row in 1...max(1, rows) {
            for column in 1...max(1, columns) {
                let position = WellPosition(row: row, column: column)
                guard !existing.contains(position) else { continue }
                let well = PaletteWell(row: row, column: column)
                well.box = self
                context.insert(well)
                changed = true
            }
        }

        if changed {
            updatedAt = .now
        }
        return changed
    }
}

// MARK: - 单个格子

@Model
final class PaletteWell {

    var row: Int
    var column: Int
    var levelRaw: Int
    var lastRefilledAt: Date?
    var note: String

    var box: PaletteBox?

    /// 这一格当前装的颜料。nil 表示还是空的 / 没装。
    var color: PaintColor?

    init(
        row: Int,
        column: Int,
        level: WellLevel = .empty,
        lastRefilledAt: Date? = nil,
        note: String = "",
        color: PaintColor? = nil
    ) {
        self.row = row
        self.column = column
        self.levelRaw = level.rawValue
        self.lastRefilledAt = lastRefilledAt
        self.note = note
        self.color = color
    }
}

// MARK: - 枚举桥接与派生

extension PaletteWell {

    var level: WellLevel {
        get { WellLevel(rawValue: levelRaw) ?? .empty }
        set { levelRaw = newValue.rawValue }
    }

    var position: WellPosition {
        WellPosition(row: row, column: column)
    }

    var positionLabel: String {
        position.label
    }

    /// 是否已装颜色。
    var isAssigned: Bool {
        color != nil
    }

    /// 展示名：有颜色就用颜色名，否则显示位置。
    var displayName: String {
        color?.name ?? "空格 \(positionLabel)"
    }

    /// 距离上次补充过了多久。
    var timeSinceRefill: TimeInterval? {
        guard let lastRefilledAt else { return nil }
        return Date.now.timeIntervalSince(lastRefilledAt)
    }
}
