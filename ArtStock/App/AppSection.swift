//
//  AppSection.swift
//  ArtAssist — 美术生的工具箱
//
//  侧边栏的四个分区。
//
//  刻意只留少数几个。上一版有十来个条目（总览、全部材料、待补货、临期提醒、
//  已归档、分类×12、扫码记录、出入库流水、标签打印、设置）—— 那是仓库软件的
//  信息架构。个人一盒颜料，真正需要来回切的只有这几处。
//
//  "颜色库"是后加的：预设色值不可能对每个人都准，得有个地方能改。
//  它不是库存视图，是**校正色值**的入口，跟"库存与采购"职责不重叠。
//
//  「其他耗材」原来是个独立分区，后来**并进了「库存与采购」**：
//  真实反馈「其他耗材也应该直接纳入库存与采购体系中啊」。
//  分成两处时，用户想知道"我总共该买什么"得跑两个地方自己加，
//  而那正是这个 App 最该替他回答的问题。
//

import Foundation

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    /// 主界面：7×6 网格。
    case palette
    /// 颜料湿润计时器。
    case wetness
    /// 教材：搜索、下载、离线阅读、Apple Pencil 批注。
    case textbooks
    /// 颜色库：42 个预设色 + 自己扫码/新建的颜色都在这里改。
    case colors
    /// 全部库存与购买建议 —— 颜料补充装 + 其他耗材都在这里。
    case stock
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .palette: return "颜料盒"
        case .colors: return "颜色库"
        case .wetness: return "保湿计时"
        case .textbooks: return "教材"
        case .stock: return "库存与采购"
        case .settings: return "设置"
        }
    }

    var symbolName: String {
        switch self {
        case .palette: return "square.grid.3x3.fill"
        case .colors: return "paintpalette.fill"
        case .wetness: return "timer"
        case .textbooks: return "books.vertical.fill"
        case .stock: return "shippingbox.fill"
        case .settings: return "gearshape.fill"
        }
    }
}
