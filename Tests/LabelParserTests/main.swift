//
//  PaintLabelParser 回归测试
//
//  OCR 的准确率没法离线测（要相机、要真包装），但**文字 → 颜色**的推断逻辑
//  必须测得动，否则改一个正则就可能把 42 个颜色全认错。
//
//  这里的样例都是照真实颜料管上印的内容写的：
//      「马利牌水粉画颜料」/「群青」/「35」/「净含量 5ml」/「PW6」
//
//  用法：./scripts/run-label-tests.sh
//

import Foundation

var passed = 0
var failed = 0

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { passed += 1; print("  ✅ \(label)") }
    else { failed += 1; print("  ❌ \(label)\(detail().isEmpty ? "" : "  → \(detail())")") }
}

let known = PaintLabelParser.presetKnown

// ═══ 1. 中文颜色名（主用例）═══
print("═══ 1. 中文颜色名（最要紧的一条路）═══")

// 真实排版：品牌 / 颜色名 / 色号 / 容量 分成几行
let tube = PaintLabelParser.parse(text: """
马利牌水粉画颜料
群青
NO.35
净含量 5ml
""", known: known)
check("认出「群青」", tube.colorName == "群青", tube.colorName ?? "nil")
check("落到预设色号 PRESET-35", tube.suggestedCode == "PRESET-35", tube.suggestedCode)
check("匹配方式是完全匹配", tube.matchKind == .exact, tube.matchKind.rawValue)
check("置信度够直接入库", tube.isConfident)
check("顺带认出编号 35", tube.productCode == "35", tube.productCode ?? "nil")
check("认出品牌马利", tube.brand == "马利", tube.brand ?? "nil")

// 逐色扫一遍：42 个中文名必须全部能对上自己的色号
var mismatched: [String] = []
for preset in PresetColors.standard42 {
    let draft = PaintLabelParser.parse(text: preset.name, known: known)
    if draft.suggestedCode != PresetColors.code(forIndex: preset.index) {
        mismatched.append("\(preset.name)→\(draft.suggestedCode.isEmpty ? "无" : draft.suggestedCode)")
    }
}
check("42 个颜色名逐个都能对上号", mismatched.isEmpty, mismatched.joined(separator: ", "))

// 带「色」后缀：「深红色」也应该认成「深红」
let withSuffix = PaintLabelParser.parse(text: "深红色", known: known)
check("「深红色」认成「深红」", withSuffix.colorName == "深红", withSuffix.colorName ?? "nil")

// 名字混在整行里：「马利 群青 5ml」
let inline = PaintLabelParser.parse(text: "马利 群青 净含量5ml", known: known)
check("混在整行里也能挑出「群青」", inline.colorName == "群青", inline.colorName ?? "nil")

// OCR 漏字：「群」应能对上「群青」
let truncated = PaintLabelParser.parse(text: "群", known: known)
check("只读到「群」也能猜出「群青」", truncated.colorName == "群青", truncated.colorName ?? "nil")
check("但标记为需要确认", truncated.matchKind == .contains && !truncated.isConfident,
      "\(truncated.matchKind.rawValue) confident=\(truncated.isConfident)")

// ═══ 2. Colour Index 标准号 ═══
print("\n═══ 2. Colour Index 颜料标准号 ═══")
let ciCases: [(String, String, String)] = [
    ("钛白 PW6", "PW6", "PRESET-01"),
    ("P.B.29 群青", "PB29", "PRESET-35"),
    ("PR 106 朱红", "PR106", "PRESET-10"),
    ("PBr7 熟褐", "PBr7", "PRESET-14"),
    ("钴蓝 P.B.28", "PB28", "PRESET-40"),
    ("土黄 PY43", "PY43", "PRESET-07")
]
var ciFailures: [String] = []
for (text, expectedCI, expectedCode) in ciCases {
    let draft = PaintLabelParser.parse(text: text, known: known)
    if draft.ciCode != expectedCI { ciFailures.append("\(text): ci=\(draft.ciCode ?? "nil") 期望 \(expectedCI)") }
    if draft.suggestedCode != expectedCode { ciFailures.append("\(text): code=\(draft.suggestedCode) 期望 \(expectedCode)") }
}
check("6 种写法都能提取标准号并对上颜色", ciFailures.isEmpty, ciFailures.joined(separator: "; "))

// 光"能对上号"不够 —— 颜色名那条路也能对上号，会把 C.I. 匹配的 bug 盖住。
// 必须断言 matchKind 确实是 .ciCode。
var kindFailures: [String] = []
for (text, _, _) in ciCases {
    let draft = PaintLabelParser.parse(text: text, known: known)
    if draft.matchKind != .ciCode { kindFailures.append("\(text)→\(draft.matchKind.rawValue)") }
}
check("这 6 个确实是靠标准号匹配的（不是靠名字）", kindFailures.isEmpty, kindFailures.joined(separator: "; "))

// 假阳性防护：普通英文单词里不能切出标准号
let falsePositives = ["HAPPY2024", "PB", "P", "PUBLIC2024", "PIZZA12", "PROMO2024"]
var leaked: [String] = []
for text in falsePositives {
    if let ci = PaintLabelParser.extractCICode(from: text) { leaked.append("\(text)→\(ci)") }
}
check("普通英文不会误报标准号", leaked.isEmpty, leaked.joined(separator: ", "))

// 前导 0 不是合法写法
check("PW06 不算合法标准号", PaintLabelParser.extractCICode(from: "PW06") == nil,
      PaintLabelParser.extractCICode(from: "PW06") ?? "nil")

// ═══ 3. 编号提取 ═══
print("\n═══ 3. 色号 / 编号提取 ═══")
let codeCases: [(String, String?)] = [
    ("NO.35", "35"),
    ("编号：A12", "A12"),
    ("货号 M-35", "M-35"),
    ("#108", "108"),
    ("色号 24", "24"),
    ("6901234567892", "6901234567892"),  // EAN-13
    ("净含量 5ml", nil)
]
var codeFailures: [String] = []
for (text, expected) in codeCases {
    let got = PaintLabelParser.extractProductCode(from: text)
    if got != expected { codeFailures.append("\(text)→\(got ?? "nil") 期望 \(expected ?? "nil")") }
}
check("7 种编号写法都对", codeFailures.isEmpty, codeFailures.joined(separator: "; "))

// ═══ 4. 全角与噪声 ═══
print("\n═══ 4. 全角 / 噪声 / 空输入 ═══")
let fullWidth = PaintLabelParser.parse(text: "米娅　深红　ＮＯ．１２", known: known)
check("全角空格与数字都能处理", fullWidth.colorName == "深红", fullWidth.colorName ?? "nil")
check("全角编号也能读出来", fullWidth.productCode == "12" || fullWidth.productCode == "NO12",
      fullWidth.productCode ?? "nil")

let empty = PaintLabelParser.parse(text: "", known: known)
check("空输入不崩且给出提示", empty.colorName == nil && !empty.warnings.isEmpty,
      "warnings=\(empty.warnings.count)")
check("空输入建议码号为空", empty.suggestedCode.isEmpty, empty.suggestedCode)

let junk = PaintLabelParser.parse(text: "净含量 5ml\n生产日期 2024.03\n上海某某美术用品有限公司", known: known)
check("纯说明文字不会瞎认颜色", junk.colorName == nil, junk.colorName ?? "nil")
check("纯说明文字会提示重新对准", junk.warnings.contains { $0.contains("没认出颜色名") },
      junk.warnings.joined(separator: " | "))

// 换行被 OCR 拼成一行也要能认
let oneLine = PaintLabelParser.parse(text: "马利牌 群青 5ml 上海马利画材", known: known)
check("整行连写也能挑出颜色名", oneLine.colorName == "群青", oneLine.colorName ?? "nil")

// ═══ 5. 易混色 ═══
print("\n═══ 5. 容易混的颜色 ═══")
// 「深红」和「大红」只差一个字，必须各认各的
let darkRed = PaintLabelParser.parse(text: "深红", known: known)
let brightRed = PaintLabelParser.parse(text: "大红", known: known)
check("深红 → PRESET-12", darkRed.suggestedCode == "PRESET-12", darkRed.suggestedCode)
check("大红 → PRESET-11", brightRed.suggestedCode == "PRESET-11", brightRed.suggestedCode)
check("两者不会互相串", darkRed.colorName != brightRed.colorName)

// 「淡绿 / 草绿 / 墨绿 / 橄榄绿 / 黄绿」五个绿
let greens = ["淡绿", "草绿", "墨绿", "橄榄绿", "黄绿"]
var greenCodes = Set<String>()
for green in greens {
    greenCodes.insert(PaintLabelParser.parse(text: green, known: known).suggestedCode)
}
check("五个绿名字各自对上不同色号", greenCodes.count == greens.count, greenCodes.sorted().joined(separator: ", "))

// 「钛白」不该被「白色」抢走；「淡黄/嫩黄/中黄/土黄/柠檬黄」同理
let yellows = ["淡黄", "嫩黄", "中黄", "土黄", "柠檬黄", "那坡里黄"]
var yellowCodes = Set<String>()
for yellow in yellows {
    yellowCodes.insert(PaintLabelParser.parse(text: yellow, known: known).suggestedCode)
}
check("六个黄色名字各自对上不同色号", yellowCodes.count == yellows.count, yellowCodes.sorted().joined(separator: ", "))

// ═══ 6. 同色号歧义 ═══
print("\n═══ 6. 一个标准号对应多个颜色时 ═══")
// 构造一个"两个颜色共享 PBr7"的已知集合
let ambiguousKnown = [
    KnownLabelColor(code: "A-1", name: "熟褐", ciCode: "PBr7", hex: "#8A3324"),
    KnownLabelColor(code: "A-2", name: "生褐", ciCode: "PBr7", hex: "#6B4423")
]
let ambiguous = PaintLabelParser.parse(text: "PBr7", known: ambiguousKnown)
check("不崩，取第一个并给出确认提示", ambiguous.matchedCode != nil && !ambiguous.warnings.isEmpty,
      ambiguous.warnings.joined(separator: " | "))
let disambiguated = PaintLabelParser.parse(text: "PBr7 生褐", known: ambiguousKnown)
check("文字里也有颜色名时按名字选", disambiguated.matchedCode == "A-2", disambiguated.matchedCode ?? "nil")

// ═══ 7. 与颜色库联动 ═══
print("\n═══ 7. 与已有颜色库联动 ═══")
// 用户自己建的颜色也应该能被认出来
let customKnown = known + [KnownLabelColor(code: "MINE-1", name: "天青蓝", ciCode: nil, hex: "#5B8FF9")]
let custom = PaintLabelParser.parse(text: "天青蓝", known: customKnown)
check("自定义颜色也能匹配", custom.suggestedCode == "MINE-1", custom.suggestedCode)
check("匹配到已知颜色时不新建", custom.suggestedCode == "MINE-1" && !custom.suggestedCode.hasPrefix("OCR-"))

// 库里没有的颜色 → 建议新建一个 OCR- 前缀的码
let brandNew = PaintLabelParser.parse(text: "孔雀绿", known: known)
check("库里没有则建议新建", brandNew.suggestedCode.hasPrefix("OCR-"), brandNew.suggestedCode)
check("新建时给出提示", brandNew.warnings.contains { $0.contains("还没有") },
      brandNew.warnings.joined(separator: " | "))

// ═══ 8. 规范化的边角 ═══
print("\n═══ 8. 规范化 ═══")
check("全角转半角", PaintLabelParser.normalizeAlphanumeric("ＮＯ１２") == "NO12",
      PaintLabelParser.normalizeAlphanumeric("ＮＯ１２"))
check("标点被去掉", PaintLabelParser.normalizeAlphanumeric("群青·5ml") == "群青5ML",
      PaintLabelParser.normalizeAlphanumeric("群青·5ml"))
check("slug 去掉标点", PaintLabelParser.slug("群青 35#") == "群青-35",
      PaintLabelParser.slug("群青 35#"))
check("slug 不留首尾横线", PaintLabelParser.slug(" 深红 ").hasPrefix("-") == false,
      PaintLabelParser.slug(" 深红 "))
check("二gram 相同文本为 1", PaintLabelParser.diceCoefficient("群青", "群青") == 1.0)
check("二gram 无关文本为 0", PaintLabelParser.diceCoefficient("群青", "柠檬") == 0.0)

print("\n═══════════════════════════════════════════════════════")
print("通过 \(passed)  失败 \(failed)")
exit(failed == 0 ? 0 : 1)
