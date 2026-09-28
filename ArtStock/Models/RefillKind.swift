//
//  RefillKind.swift
//  ArtAssist — 美术生的工具箱
//
//  两种补充装。**这个文件刻意不 import SwiftData。**
//
//  为什么单独放一个文件：它是纯枚举 + 纯派生逻辑，却被关在
//  `PaintColor.swift`（一个 @Model 文件）里。后果是任何想用它做纯逻辑测试的
//  地方都得把 SwiftData 一起拖进来，在 macOS 上就编不过 ——
//  收包裹解析（PackageParsing）正好撞上这一点。
//
//  模型文件负责"存什么"，这种纯枚举文件负责"怎么算"。
//  分开之后两边都能单独测。
//

import Foundation

// MARK: - 补充装类型

/// 两种补充装。它们的消耗方式完全不同，所以库存必须分开记。
enum RefillKind: String, CaseIterable, Codable, Identifiable, Sendable {
    /// **挤出补充装**：一支软管，挤进格子里。一支能补好几格。
    case squeeze
    /// **直接替换装**：一个预装颜料块，整格换掉。一格换一个，用完即尽。
    case pan

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .squeeze: return "挤出补充装"
        case .pan: return "直接替换装"
        }
    }

    var shortName: String {
        switch self {
        case .squeeze: return "挤出装"
        case .pan: return "替换装"
        }
    }

    var symbolName: String {
        switch self {
        case .squeeze: return "tube"
        case .pan: return "square.grid.2x2"
        }
    }

    /// 单位的量词：一支 / 一个。
    var unitName: String {
        switch self {
        case .squeeze: return "支"
        case .pan: return "个"
        }
    }

    var explanation: String {
        switch self {
        case .squeeze: return "软管装，挤进格子里。一支能补好几格 —— 所以要在下面填「一支能补几格」。"
        case .pan: return "预装颜料块，整格换掉。一格换一个，用完即尽，不需要填每件补几格。"
        }
    }

    /// 直接替换装固定「一件补一格」；挤出补充装由用户填写。
    var defaultCapacityPerUnit: Int {
        switch self {
        case .squeeze: return 3
        case .pan: return 1
        }
    }

    /// 该类型的每单位可补格数是否由用户填写。
    var capacityIsUserDefined: Bool {
        self == .squeeze
    }
}
