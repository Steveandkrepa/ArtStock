//
//  PresetColors 数据完整性测试
//
//  预设色卡是**数据**，而数据最容易出低级错误：色值少一位、
//  序号重了、颜色名敲错、数量对不上 7×6=42。
//  这些都不会让编译失败，但会让用户装出来一盒错的颜色。
//
//  ⚠️ 这一套在"色值来自厂家色卡实测"之后改过：
//     以前断言的是"色值等于 W3C 规范值"，那是**错的假设** ——
//     颜料没有 RGB 国际标准，「马尔代夫」被套成 turquoise(#40E0D0) 就是那么来的。
//     现在断言的是"来源必须是实测"以及一批**物理性质**（白要够白、
//     黑要够黑、马尔代夫得是绿的），这些是实测数据真正能保证的东西。
//
//  用法：./scripts/run-preset-tests.sh
//

import Foundation

var passed = 0
var failed = 0

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { passed += 1; print("  ✅ \(label)") }
    else { failed += 1; print("  ❌ \(label)\(detail().isEmpty ? "" : "  → \(detail())")") }
}

let preset = PresetColors.standard42

/// `#RRGGBB` → (r, g, b)
func rgb(_ hex: String) -> (r: Int, g: Int, b: Int)? {
    let digits = hex.dropFirst()
    guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
    return (Int((value >> 16) & 0xFF), Int((value >> 8) & 0xFF), Int(value & 0xFF))
}

/// 按名字取色。
func hexOf(_ name: String) -> String? {
    preset.first { $0.name == name }?.hex
}

print("═══ 1. 数量与盒子匹配 ═══")
// 7×6 = 42，预设必须正好装满一盒，多一个少一个都会错位。
check("预设正好 42 个（= 7×6）", preset.count == 42, "actual=\(preset.count)")
check("序号从 1 连续到 42",
      preset.map(\.index) == Array(1...42),
      "first=\(preset.first?.index ?? -1) last=\(preset.last?.index ?? -1)")

print("\n═══ 2. 色值格式 ═══")
let hexPattern = try! NSRegularExpression(pattern: "^#[0-9A-F]{6}$")
var badHex: [String] = []
for color in preset {
    let range = NSRange(color.hex.startIndex..., in: color.hex)
    if hexPattern.firstMatch(in: color.hex, range: range) == nil {
        badHex.append("\(color.name)=\(color.hex)")
    }
}
check("全部色值都是 #RRGGBB 大写十六进制", badHex.isEmpty, badHex.joined(separator: ", "))
check("全部色值都能解析成 RGB", preset.allSatisfy { rgb($0.hex) != nil })

print("\n═══ 3. 无重复 ═══")
let names = preset.map(\.name)
check("颜色名不重复", Set(names).count == names.count,
      "重复: \(Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted())")
let codes = preset.map { PresetColors.code(forIndex: $0.index) }
check("生成的色号不重复", Set(codes).count == codes.count)
check("色号格式统一为 PRESET-NN",
      codes.allSatisfy { $0.hasPrefix("PRESET-") && $0.count == 9 },
      codes.first ?? "")
// 两个颜色一模一样的话，用户根本分不出哪格是哪个 —— 实测数据不该撞色。
let hexes = preset.map(\.hex)
check("42 个色值互不相同", Set(hexes).count == hexes.count,
      Dictionary(grouping: hexes, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted().joined(separator: ", "))

print("\n═══ 4. 来源必须是实测（这次改动的核心）═══")
// 上一版 42 个色值全是按色名猜的，把「马尔代夫」猜成了蓝色。
// 现在只认一档：厂家色卡实测。这条断言就是"不许再往回塞猜的值"。
check("42 个色值全部来自厂家色卡实测",
      preset.allSatisfy { $0.source == .colorCard },
      preset.filter { $0.source != .colorCard }.map { "\($0.name)=\($0.source.rawValue)" }.joined(separator: ", "))
check("没有任何一个颜色用的是描述性（猜测）来源",
      preset.allSatisfy { $0.source != .descriptive },
      preset.filter { $0.source == .descriptive }.map(\.name).joined(separator: ", "))

print("\n═══ 5. 物理性质：实测数据真正能保证的东西 ═══")
// 明度锚点：白要够白、黑要够黑，否则调不出明度层次
do {
    let white = rgb(hexOf("钛白") ?? "") ?? (0, 0, 0)
    check("钛白三通道都在 245 以上（够白）",
          white.r >= 245 && white.g >= 245 && white.b >= 245,
          hexOf("钛白") ?? "nil")
    let black = rgb(hexOf("黑色") ?? "") ?? (255, 255, 255)
    check("黑色三通道都在 20 以下（够黑）",
          black.r <= 20 && black.g <= 20 && black.b <= 20,
          hexOf("黑色") ?? "nil")
    check("钛白比黑色亮得多",
          white.r + white.g + white.b > black.r + black.g + black.b + 600)
}
check("包含白色系", preset.contains { $0.name.contains("白") })
check("包含黑色", preset.contains { $0.name == "黑色" })

// 色相锚点：这次就是被这些抓出来的错
var hueFailures: [String] = []
do {
    // 「马尔代夫」上一版是 #40E0D0（蓝的），实物是绿的 —— 真实反馈
    let maldives = rgb(hexOf("马尔代夫") ?? "") ?? (0, 0, 0)
    if !(maldives.g > maldives.r && maldives.g > maldives.b) {
        hueFailures.append("马尔代夫 \(hexOf("马尔代夫") ?? "nil") 应该是绿的")
    }
    // 绿系名字必须 G 最大
    for name in ["淡绿", "草绿", "橄榄绿", "墨绿", "青苹果", "黄绿", "起司", "香水百合"] {
        guard let c = rgb(hexOf(name) ?? "") else { continue }
        if !(c.g >= c.r && c.g >= c.b) { hueFailures.append("\(name) \(hexOf(name) ?? "nil") 应该偏绿") }
    }
    // 蓝系名字必须 B 最大
    for name in ["群青", "普蓝", "钴蓝", "湖蓝", "天蓝", "晴朗蓝", "浅灰蓝", "青竹蓝"] {
        guard let c = rgb(hexOf(name) ?? "") else { continue }
        if !(c.b >= c.r && c.b >= c.g) { hueFailures.append("\(name) \(hexOf(name) ?? "nil") 应该偏蓝") }
    }
    // 红系名字必须 R 最大
    for name in ["朱红", "大红", "深红", "玫瑰红", "蔷薇"] {
        guard let c = rgb(hexOf(name) ?? "") else { continue }
        if !(c.r >= c.g && c.r >= c.b) { hueFailures.append("\(name) \(hexOf(name) ?? "nil") 应该偏红") }
    }
    // 黄系名字必须 R、G 都明显高于 B
    for name in ["柠檬黄", "嫩黄", "淡黄", "中黄", "那坡里黄"] {
        guard let c = rgb(hexOf(name) ?? "") else { continue }
        if !(c.r > c.b + 40 && c.g > c.b + 40) {
            hueFailures.append("\(name) \(hexOf(name) ?? "nil") 应该偏黄")
        }
    }
    // 褐系名字必须 R > G > B 且偏暗
    for name in ["熟褐", "赭石"] {
        guard let c = rgb(hexOf(name) ?? "") else { continue }
        if !(c.r > c.g && c.g > c.b && c.r < 180) {
            hueFailures.append("\(name) \(hexOf(name) ?? "nil") 应该是暗棕")
        }
    }
}
check("色相锚点全部正确（绿是绿、蓝是蓝、红是红、黄是黄、褐是暗棕）",
      hueFailures.isEmpty, hueFailures.joined(separator: "; "))

print("\n═══ 6. 与用户给出的清单一致 ═══")
let expected = ["钛白", "那坡里黄", "柠檬黄", "嫩黄", "淡黄", "中黄", "土黄", "桔黄", "桔红", "朱红",
                "大红", "深红", "赭石", "熟褐", "豆沙红", "肉色", "米驼", "蔷薇", "紫丁香", "淡紫",
                "玫瑰红", "香水百合", "青苹果", "黄绿", "淡绿", "草绿", "橄榄绿", "墨绿", "起司", "马尔代夫",
                "春日青", "晴朗蓝", "浅蟹灰", "紫罗兰", "群青", "浅灰蓝", "青竹蓝", "天蓝", "湖蓝", "钴蓝",
                "普蓝", "黑色"]
check("清单长度 42", expected.count == 42, "actual=\(expected.count)")
if expected.count == preset.count {
    let mismatches = zip(expected, preset).enumerated().compactMap { offset, pair -> String? in
        pair.0 == pair.1.name ? nil : "第\(offset + 1)个: 期望「\(pair.0)」实际「\(pair.1.name)」"
    }
    check("顺序与色卡逐个一致", mismatches.isEmpty, mismatches.joined(separator: "; "))
} else {
    check("顺序与色卡逐个一致", false, "数量不一致，无法逐项比对")
}

print("\n═══ 7. 色相分布合理性 ═══")
// 按 HSV 的色相粗略检查：一盒水粉应该覆盖色轮上有意义的几个区间。
func hue(_ hex: String) -> Double? {
    guard let c = rgb(hex) else { return nil }
    let r = Double(c.r) / 255, g = Double(c.g) / 255, b = Double(c.b) / 255
    let maxV = max(r, g, b), minV = min(r, g, b)
    guard maxV != minV else { return nil }   // 灰阶没有色相
    let delta = maxV - minV
    var h: Double
    if maxV == r { h = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6)) }
    else if maxV == g { h = 60 * ((b - r) / delta + 2) }
    else { h = 60 * ((r - g) / delta + 4) }
    return h < 0 ? h + 360 : h
}
let hues = preset.compactMap { hue($0.hex) }
check("有足够多的彩色（非灰阶）", hues.count >= 38, "彩色 \(hues.count) 个")
// 红(0/360)、黄(60)、绿(120)、青(180)、蓝(240)、紫(280) 六个区间都要有
for base in [0, 60, 120, 180, 240, 300] {
    let hit = hues.contains { h in
        let diff = abs(h - Double(base))
        return min(diff, 360 - diff) < 30
    }
    check("色轮 \(base)° 附近有颜色", hit)
}

print("\n═══ 8. Colour Index 颜料标准号 ═══")
// C.I. 是颜料领域真正通行的国际标准 —— 它规定的是**化学成分**，不是 RGB。
// 格式固定：P + 类别字母 + 编号，例如 PW6（白 6）、PB29（蓝 29）、PR106（红 106）。
// 双字母类别来自 Colour Index 的通用分类：Bk=黑、Br=棕，其余为单字母。
let ciPattern = try! NSRegularExpression(pattern: "^P(Bk|Br|W|Y|O|R|V|B|G)[0-9]{1,3}$")
var badCI: [String] = []
var ciCodes: [String] = []
for color in preset {
    guard let ci = color.ciCode else { continue }
    ciCodes.append(ci)
    let range = NSRange(ci.startIndex..., in: ci)
    if ciPattern.firstMatch(in: ci, range: range) == nil { badCI.append("\(color.name)=\(ci)") }
}
check("有标准号的颜色都符合 P+类别+编号 格式", badCI.isEmpty, badCI.joined(separator: ", "))
check("标准号不重复", Set(ciCodes).count == ciCodes.count,
      Dictionary(grouping: ciCodes, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted().joined(separator: ", "))

// 宁缺勿滥：只有"色名 → 颜料化学成分"在行业里没有歧义的才标号。
// 编一个看起来很像的号比留空更糟 —— 留空用户会去管子上看，编错了用户会信。
check("颜料标准号数量在合理区间（宁缺勿滥）",
      (6...12).contains(ciCodes.count), "有 \(ciCodes.count) 个：\(ciCodes.joined(separator: " "))")
check("标了 .pigment 来源的必须有标准号",
      preset.allSatisfy { $0.source != .pigment || $0.ciCode != nil })
check("描述性色值一律不许带标准号",
      preset.allSatisfy { $0.source != .descriptive || $0.ciCode == nil })

// 这 8 个的映射是行业里公认无歧义的，逐个钉死。
let ciExpectations: [String: String] = [
    "钛白": "PW6",     // titanium dioxide
    "那坡里黄": "PY41", // Naples yellow
    "土黄": "PY43",    // yellow ochre / 黄氧化铁
    "朱红": "PR106",   // vermilion / 硫化汞
    "熟褐": "PBr7",    // burnt umber
    "群青": "PB29",    // ultramarine
    "钴蓝": "PB28",    // cobalt blue
    "普蓝": "PB27"     // Prussian blue
]
var wrongCI: [String] = []
for (name, expectedCI) in ciExpectations {
    guard let color = preset.first(where: { $0.name == name }) else {
        wrongCI.append("\(name) 不存在"); continue
    }
    if color.ciCode != expectedCI { wrongCI.append("\(name)=\(color.ciCode ?? "nil") 应为 \(expectedCI)") }
}
check("8 个无歧义颜料的标准号逐个正确", wrongCI.isEmpty, wrongCI.joined(separator: " / "))
check("标准号清单没有多余的（即只有这 8 个）", ciCodes.count == ciExpectations.count,
      "实际 \(ciCodes.count) 个，期望 \(ciExpectations.count) 个")

print("\n═══ 9. 数据版本 ═══")
// 老版本装过预设、色值是猜的（马尔代夫是蓝的）。启动时靠这个版本号自动刷一次。
check("数据版本已提升到 2（色卡实测）", PresetColors.dataVersion == 2,
      "\(PresetColors.dataVersion)")

print("\n═══════════════════════════════════════════════════════")
print("通过 \(passed)  失败 \(failed)")
exit(failed == 0 ? 0 : 1)
