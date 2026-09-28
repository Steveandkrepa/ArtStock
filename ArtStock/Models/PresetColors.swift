//
//  PresetColors.swift
//  ArtAssist — 美术生的工具箱
//
//  42 色水粉预设色卡 —— 正好对应 7×6 的一整盒。
//
//  ── 色值是从哪来的（这一版才说清楚）─────────────────────────
//  **厂家色卡实测**：用户提供了这盒颜料的官方 42 色色卡图，
//  42 个色值是把色卡上每一格的色块逐格采下来的 —— 不是按色名猜的。
//
//  采集过程（脚本 + 两次校验，都在这次改动里做过）：
//    1. 先测出**真实格子边界**：卡片有内白边、格子之间有白缝，
//       所以不能简单地把卡片范围除以 7 和 6（第一次就是这么错的，采出了偏移值）
//    2. 每格只取上半部分 —— 下半是半透明的名字色带，采进去会把颜色压暗
//    3. 校验取色区间是否敏感：换一个区间最大通道差只有 2/255 → 色块基本是平的
//    4. 校验关键锚点：钛白 #FEFEFE、黑色 #030304、马尔代夫是绿的、群青是深蓝
//
//  ── 之前错在哪（留个记录，别再犯）───────────────────────────
//  上一版这 42 个色值是我**按色名硬套**出来的：
//  「马尔代夫」套了 W3C 的 turquoise(#40E0D0) → 显示成蓝色，
//  而实物是绿色。真实反馈：「像马尔代夫就根本不像啊颜色，是个绿色的」。
//
//  根因是：颜料领域**没有 RGB 的国际标准**。
//    · Colour Index（C.I.）规定的是**化学成分**，不是 RGB
//    · W3C CSS 只有 148 个具名颜色，跟「马尔代夫」「起司」这些
//      **品牌自创色名**没有任何对应关系
//  所以"查一个更权威的表"这条路根本不存在 —— 只能从实物或厂家色卡上采。
//
//  ── 还剩多少不确定性 ────────────────────────────────────────
//  色卡是屏幕上的图，屏幕显色与实物在画室灯光下的观感仍有差距；
//  同一品牌不同批次也会有微差。所以「取色校准」保留：
//  把打开的颜料盒对着相机采一遍，采过的颜色打「已校准」标记，
//  之后不会被任何操作覆盖（包括「刷成标准值」）。
//
//  ── 顺序即实物布局 ───────────────────────────────────────────
//  下面的顺序**就是**这盒颜料的排布顺序（从左到右、从上到下），
//  所以「载入预设」会把第 1 个「钛白」放进 A1、第 42 个「黑色」放进最后一格。
//

import Foundation

/// 一个预设颜色。
struct PresetColor: Hashable, Sendable {
    var name: String
    var hex: String
    /// 在 42 色盒里的序号（1 起）。
    var index: Int
    /// **Colour Index 国际颜料标准号**，例如 `PW6`（钛白）、`PB29`（群青）。
    ///
    /// 这是颜料领域真正意义上的国际标准 —— 它规定的是**化学成分**，不是 RGB。
    /// 各国对颜色的叫法完全不同，但 `PB29` 全球唯一。
    ///
    /// 为 nil 表示这个中文色名对应的颜料成分有歧义，或者干脆是品牌自创色名。
    /// **故意留空，不猜。**
    var ciCode: String?
    /// 色值的依据，便于日后核对。
    var source: ColorSource

    enum ColorSource: String, Sendable {
        /// 厂家色卡实测 —— 从用户提供的官方色卡上逐格采样。当前 42 个全是这一档。
        case colorCard = "厂家色卡实测"
        /// W3C CSS Color Module 的具名颜色，色值即规范值。
        case w3c = "W3C CSS 标准色名"
        /// 按 Colour Index 颜料号取的通行的代表性色值（非规范性色值）。
        case pigment = "颜料标准参考值"
        /// 无标准可依、按色名猜的描述性色值。
        ///
        /// **当前一个都不用** —— 上一版用这一档把「马尔代夫」猜成了蓝色。
        /// 留着这个 case 是为了标记"这一档不可信"，不是给人往里塞值的。
        case descriptive = "描述性色值（不可信，已被实测取代）"
    }
}

enum PresetColors {

    /// 色卡数据版本。
    ///
    /// 用途：老版本装过预设、色值是按色名猜的（比如马尔代夫是蓝的）。
    /// 启动时发现本地版本落后就自动刷一次，用户不用自己去找菜单。
    /// 已校准 / 改过名的颜色不会被碰 —— 见 `PaletteService.refreshPresetColors`。
    ///
    ///   1 = 按色名猜的（旧）
    ///   2 = 厂家色卡实测（当前）
    static let dataVersion = 2

    /// 42 色水粉预设。顺序 = 实物颜料盒的排布顺序。
    ///
    /// 色值来源：用户提供的厂家 42 色色卡，逐格采样。
    /// Colour Index 号只标 8 个 —— 只有这 8 个的"色名 → 颜料成分"没有歧义，
    /// 其余留空。**编一个看起来很像的号比留空更糟**：留空你会去管子上看，
    /// 编错了你会信。
    static let standard42: [PresetColor] = [
        // ── 第 1 行：白与黄 ──
        PresetColor(name: "钛白", hex: "#FEFEFE", index: 1, ciCode: "PW6", source: .colorCard),
        PresetColor(name: "那坡里黄", hex: "#F6DC8C", index: 2, ciCode: "PY41", source: .colorCard),
        PresetColor(name: "柠檬黄", hex: "#EFE72B", index: 3, ciCode: nil, source: .colorCard),
        PresetColor(name: "嫩黄", hex: "#EAE096", index: 4, ciCode: nil, source: .colorCard),
        PresetColor(name: "淡黄", hex: "#FEDF09", index: 5, ciCode: nil, source: .colorCard),
        PresetColor(name: "中黄", hex: "#F5A708", index: 6, ciCode: nil, source: .colorCard),

        // ── 第 2 行：黄橙红 ──
        PresetColor(name: "土黄", hex: "#BB831B", index: 7, ciCode: "PY43", source: .colorCard),
        PresetColor(name: "桔黄", hex: "#D56819", index: 8, ciCode: nil, source: .colorCard),
        PresetColor(name: "桔红", hex: "#D05619", index: 9, ciCode: nil, source: .colorCard),
        PresetColor(name: "朱红", hex: "#D43322", index: 10, ciCode: "PR106", source: .colorCard),
        PresetColor(name: "大红", hex: "#CF2326", index: 11, ciCode: nil, source: .colorCard),
        PresetColor(name: "深红", hex: "#B4222A", index: 12, ciCode: nil, source: .colorCard),

        // ── 第 3 行：土色与肤色 ──
        PresetColor(name: "赭石", hex: "#804022", index: 13, ciCode: nil, source: .colorCard),
        PresetColor(name: "熟褐", hex: "#502E17", index: 14, ciCode: "PBr7", source: .colorCard),
        PresetColor(name: "豆沙红", hex: "#B06F5C", index: 15, ciCode: nil, source: .colorCard),
        PresetColor(name: "肉色", hex: "#F8D1A9", index: 16, ciCode: nil, source: .colorCard),
        PresetColor(name: "米驼", hex: "#DDD1B8", index: 17, ciCode: nil, source: .colorCard),
        PresetColor(name: "蔷薇", hex: "#EBB2CC", index: 18, ciCode: nil, source: .colorCard),

        // ── 第 4 行：紫与粉 ──
        PresetColor(name: "紫丁香", hex: "#CCB0D5", index: 19, ciCode: nil, source: .colorCard),
        PresetColor(name: "淡紫", hex: "#AD96C0", index: 20, ciCode: nil, source: .colorCard),
        PresetColor(name: "玫瑰红", hex: "#BB1A5C", index: 21, ciCode: nil, source: .colorCard),
        PresetColor(name: "香水百合", hex: "#B0C925", index: 22, ciCode: nil, source: .colorCard),
        PresetColor(name: "青苹果", hex: "#7BC070", index: 23, ciCode: nil, source: .colorCard),
        PresetColor(name: "黄绿", hex: "#7DB430", index: 24, ciCode: nil, source: .colorCard),

        // ── 第 5 行：绿与特调 ──
        PresetColor(name: "淡绿", hex: "#5AAE33", index: 25, ciCode: nil, source: .colorCard),
        PresetColor(name: "草绿", hex: "#1F602D", index: 26, ciCode: nil, source: .colorCard),
        PresetColor(name: "橄榄绿", hex: "#4A5C35", index: 27, ciCode: nil, source: .colorCard),
        PresetColor(name: "墨绿", hex: "#04523F", index: 28, ciCode: nil, source: .colorCard),
        PresetColor(name: "起司", hex: "#D8DD5D", index: 29, ciCode: nil, source: .colorCard),
        PresetColor(name: "马尔代夫", hex: "#AED47F", index: 30, ciCode: nil, source: .colorCard),

        // ── 第 6 行：青与蓝 ──
        PresetColor(name: "春日青", hex: "#B2D9D4", index: 31, ciCode: nil, source: .colorCard),
        PresetColor(name: "晴朗蓝", hex: "#A2D5D7", index: 32, ciCode: nil, source: .colorCard),
        PresetColor(name: "浅蟹灰", hex: "#85ACBC", index: 33, ciCode: nil, source: .colorCard),
        PresetColor(name: "紫罗兰", hex: "#542F87", index: 34, ciCode: nil, source: .colorCard),
        PresetColor(name: "群青", hex: "#232E62", index: 35, ciCode: "PB29", source: .colorCard),
        PresetColor(name: "浅灰蓝", hex: "#CCDEEF", index: 36, ciCode: nil, source: .colorCard),

        // ── 第 7 行：蓝与黑 ──
        PresetColor(name: "青竹蓝", hex: "#92A1D2", index: 37, ciCode: nil, source: .colorCard),
        PresetColor(name: "天蓝", hex: "#20ACD8", index: 38, ciCode: nil, source: .colorCard),
        PresetColor(name: "湖蓝", hex: "#1AA7CA", index: 39, ciCode: nil, source: .colorCard),
        PresetColor(name: "钴蓝", hex: "#4170B1", index: 40, ciCode: "PB28", source: .colorCard),
        PresetColor(name: "普蓝", hex: "#1C254B", index: 41, ciCode: "PB27", source: .colorCard),
        PresetColor(name: "黑色", hex: "#030304", index: 42, ciCode: nil, source: .colorCard),
    ]

    /// 预设色卡的名字，用于界面展示。
    static let standard42Name = "42 色水粉预设"

    /// 与 42 色一一对应的稳定色号。用序号而不是色名，避免改名后对不上。
    static func code(forIndex index: Int) -> String {
        String(format: "PRESET-%02d", index)
    }

    /// 有多少条带着可核对的 C.I. 国际标准号。
    static var pigmentStandardCount: Int {
        standard42.filter { $0.ciCode != nil }.count
    }
}
