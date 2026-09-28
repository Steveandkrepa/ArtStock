//
//  PP-OCR 字符表 / CTC 解码 / 输入归一化 测试
//
//  这三件事是「换成 PaddleOCR 模型」这条路里**最容易错、又最难发现**的部分：
//  解错一位 → 全都认出来了但每个字错位一个；归一化写错 → 能跑但认不准。
//  而它们全是纯数学 + 查表，**不需要模型就能测**。所以先测透。
//
//  字符表用的是 PaddleOCR 官方那份 ppocr_keys_v1.txt（6623 字）。
//
//  用法：./scripts/run-paddleocr-tests.sh
//

import Foundation

var passed = 0
var failed = 0

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { passed += 1; print("  ✅ \(label)") }
    else { failed += 1; print("  ❌ \(label)\(detail().isEmpty ? "" : "  → \(detail())")") }
}

func eq<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    check(label, actual == expected, "实际 \(actual) 期望 \(expected)")
}

// ═══ 1. 字符表索引约定 ═══
print("═══ 1. 字符表索引约定（错了全盘错位）═══")
do {
    let set = PPOCRCharacterSet(dictionary: "a\nb\nc", useSpaceCharacter: false)
    eq("blank 在索引 0", set.character(at: 0), "")
    eq("索引 1 是字典第一个字", set.character(at: 1), "a")
    eq("索引 3 是字典第三个字", set.character(at: 3), "c")
    // 不开空格类时：blank 占 1 个槽位，所以类别数 = 字典 + 1
    eq("不开空格类时类别数 = 字典 + 1", set.classCount, 4)
    eq("字典数不含 blank", set.dictionaryCount, 3)
    check("越界返回 nil 而不是崩", set.character(at: 99) == nil && set.character(at: -1) == nil)
}
do {
    let set = PPOCRCharacterSet(dictionary: "a\nb", useSpaceCharacter: true)
    eq("开空格时最后一类是空格", set.character(at: 3), " ")
    eq("此时类别数 = 字典 + 2", set.classCount, 4)
}
do {
    let set = PPOCRCharacterSet(dictionary: "a\nb\n", useSpaceCharacter: false)
    // blank + a + b = 3（结尾那个换行不该多出一个空字符类）
    eq("结尾换行不会多出一个空类", set.classCount, 3)
    eq("字典数仍是 2", set.dictionaryCount, 2)
    eq("索引 2 仍是 b", set.character(at: 2), "b")
}
do {
    let set = PPOCRCharacterSet(dictionary: "a\r\nb", useSpaceCharacter: false)
    eq("CRLF 也处理正确", set.character(at: 2), "b")
    eq("CRLF 不残留回车", set.character(at: 1), "a")
}

// ═══ 2. 真实字典（6623 字）═══
print("\n═══ 2. 真实字典 ppocr_keys_v1.txt ═══")
let dictPath = "Resources/ppocr_keys_v1.txt"
if let text = try? String(contentsOfFile: dictPath, encoding: .utf8) {
    let set = PPOCRCharacterSet(dictionary: text)
    eq("字典 6623 字", set.dictionaryCount, 6623)
    eq("模型输出类别数 = 6625", set.classCount, 6625)
    eq("最后一个是空格", set.character(at: 6624), " ")
    eq("0 是 blank", set.character(at: 0), "")
    check("索引 1 是真实字符（不是空）", !(set.character(at: 1) ?? "").isEmpty)

    // 常见色名用字必须在表里
    let needed = ["群", "青", "钛", "白", "深", "红", "赭", "石", "玫", "瑰", "柠", "檬"]
    let missing = needed.filter { char in
        !(1...set.dictionaryCount).contains { set.character(at: $0) == char }
    }
    check("常用色名用字都在字典里", missing.isEmpty, "缺：\(missing)")

    // 索引查找：模拟"模型输出索引 → 文字"
    if let qun = (1...set.dictionaryCount).first(where: { set.character(at: $0) == "群" }) {
        eq("按索引取回「群」", set.character(at: qun), "群")
    } else {
        check("能在字典里找到「群」", false)
    }
} else {
    check("能读到 \(dictPath)（在工作目录下运行）", false, "文件不存在")
}

// ═══ 3. CTC 贪心解码 ═══
print("\n═══ 3. CTC 解码 ═══")
do {
    let set = PPOCRCharacterSet(dictionary: "a\nb\nc", useSpaceCharacter: true)
    // 索引约定：0=blank  1=a  2=b  3=c  4=空格
    eq("单个字", PPOCRCTCDecoder.decode(indices: [1], characterSet: set), "a")
    eq("重复帧只算一个字", PPOCRCTCDecoder.decode(indices: [1, 1, 1], characterSet: set), "a")
    eq("blank 被丢掉", PPOCRCTCDecoder.decode(indices: [0, 1, 0, 2, 0], characterSet: set), "ab")
    eq("全 blank 解码为空", PPOCRCTCDecoder.decode(indices: [0, 0, 0], characterSet: set), "")
    eq("空输入解码为空", PPOCRCTCDecoder.decode(indices: [], characterSet: set), "")

    // ★ 最关键的一条：被 blank 隔开的重复字是**两个字**
    eq("a·blank·a 解成 aa（不是 a）",
       PPOCRCTCDecoder.decode(indices: [1, 0, 1], characterSet: set), "aa")
    eq("a·a·blank 解成 a",
       PPOCRCTCDecoder.decode(indices: [1, 1, 0], characterSet: set), "a")
    eq("间隔重复：ab·blank·ab 解成 abab",
       PPOCRCTCDecoder.decode(indices: [1, 2, 0, 1, 2], characterSet: set), "abab")
    eq("空格类能正常输出", PPOCRCTCDecoder.decode(indices: [1, 4, 2], characterSet: set), "a b")
    eq("越界索引被忽略而不是崩",
       PPOCRCTCDecoder.decode(indices: [1, 99, 2], characterSet: set), "ab")
}

// ═══ 4. 带置信度的解码 ═══
print("\n═══ 4. 带置信度的解码 ═══")
do {
    let set = PPOCRCharacterSet(dictionary: "a\nb", useSpaceCharacter: false)
    let logits: [[Float]] = [
        [0.1, 0.8, 0.1],   // → a（0.8）
        [0.1, 0.9, 0.0],   // → a（重复，丢弃）
        [0.9, 0.05, 0.05], // → blank
        [0.1, 0.1, 0.8]    // → b（0.8）
    ]
    let result = PPOCRCTCDecoder.decode(logits: logits, characterSet: set)
    eq("解出 ab", result.text, "ab")
    check("置信度是收下的字的均值（0.8）",
          abs(result.confidence - 0.8) < 1e-6,
          "\(result.confidence)")
    check("置信度不会被 blank 拉低", result.confidence > 0.7, "\(result.confidence)")
}
do {
    let set = PPOCRCharacterSet(dictionary: "a", useSpaceCharacter: false)
    // 看起来像 logits（和远大于 1）→ 应自动补一次 softmax
    let logits: [[Float]] = [[0.0, 5.0]]
    let result = PPOCRCTCDecoder.decode(logits: logits, characterSet: set)
    eq("logits 输入也能解对", result.text, "a")
    check("softmax 后的置信度在 0…1 之间",
          result.confidence > 0.9 && result.confidence <= 1.0,
          "\(result.confidence)")
}
do {
    let set = PPOCRCharacterSet(dictionary: "a", useSpaceCharacter: false)
    eq("空 logits 返回空", PPOCRCTCDecoder.decode(logits: [], characterSet: set).text, "")
    let allBlank: [[Float]] = [[1.0, 0.0], [1.0, 0.0]]
    eq("全 blank 返回空", PPOCRCTCDecoder.decode(logits: allBlank, characterSet: set).text, "")
    check("全 blank 置信度为 0",
          PPOCRCTCDecoder.decode(logits: allBlank, characterSet: set).confidence == 0)
}

// ═══ 5. argmax 与 softmax 容错 ═══
print("\n═══ 5. argmax / softmax ═══")
do {
    let probability = PPOCRCTCDecoder.argmax([0.2, 0.7, 0.1])
    eq("概率分布里取最大索引", probability?.index, 1)
    check("概率直接返回", abs((probability?.probability ?? 0) - 0.7) < 1e-6,
          "\(probability?.probability ?? -1)")
}
do {
    let value = PPOCRCTCDecoder.argmax([-2.0, 3.0, 0.0])
    eq("负数 logits 取最大索引", value?.index, 1)
    check("logits 被转成概率（0…1）",
          (value?.probability ?? -1) > 0 && (value?.probability ?? 2) < 1,
          "\(value?.probability ?? -1)")
}
do {
    check("空数组返回 nil", PPOCRCTCDecoder.argmax([]) == nil)
    let single = PPOCRCTCDecoder.argmax([0.5])
    eq("单元素数组", single?.index, 0)
}

// ═══ 6. 输入归一化 ═══
print("\n═══ 6. 输入归一化（写错就会能跑但认不准）═══")
do {
    check("0 → −1", abs(PPOCRInputNormalizer.normalize(0) - (-1)) < 1e-6,
          "\(PPOCRInputNormalizer.normalize(0))")
    check("255 → 1", abs(PPOCRInputNormalizer.normalize(255) - 1) < 1e-6,
          "\(PPOCRInputNormalizer.normalize(255))")
    check("128 → 接近 0（中灰）", abs(PPOCRInputNormalizer.normalize(128)) < 0.02,
          "\(PPOCRInputNormalizer.normalize(128))")
    var inRange = true
    for value in 0...255 where PPOCRInputNormalizer.normalize(UInt8(value)) < -1.0001
        || PPOCRInputNormalizer.normalize(UInt8(value)) > 1.0001 {
        inRange = false
    }
    check("归一化结果全部落在 −1…1", inRange)
}
do {
    let gray: [UInt8] = [0, 255, 128, 64]   // 2×2
    let chw = PPOCRInputNormalizer.makeCHW(gray: gray, width: 2, height: 2)
    eq("长度 = 3 × 像素数", chw.count, 12)
    check("R 平面第一像素 = −1", abs(chw[0] - (-1)) < 1e-6, "\(chw[0])")
    check("G 平面与 R 相同（灰度）", chw[0] == chw[4], "\(chw[0]) vs \(chw[4])")
    check("B 平面与 R 相同", chw[0] == chw[8], "\(chw[0]) vs \(chw[8])")
    check("第二个像素在 R 平面上", abs(chw[1] - 1) < 1e-6, "\(chw[1])")
}
do {
    check("尺寸不合法时返回空数组",
          PPOCRInputNormalizer.makeCHW(gray: [1, 2], width: 3, height: 3).isEmpty)
    check("数据不足时返回空数组",
          PPOCRInputNormalizer.makeCHW(gray: [], width: 2, height: 2).isEmpty)
}

// ═══ 7. 缩放与补齐 ═══
print("\n═══ 7. 缩放到 48 高、宽补到 8 的倍数 ═══")
do {
    let width = 100, height = 20
    let gray = [UInt8](repeating: 200, count: width * height)
    let fitted = PPOCRInputNormalizer.fit(gray: gray, width: width, height: height)
    eq("高度 = 48", fitted.height, 48)
    check("宽度是 8 的倍数", fitted.width % 8 == 0, "\(fitted.width)")
    check("宽度不超过 320", fitted.width <= 320, "\(fitted.width)")
    check("像素数与宽高一致", fitted.pixels.count == fitted.width * fitted.height,
          "\(fitted.pixels.count) vs \(fitted.width * fitted.height)")
    eq("按比例算出的宽度正确（100×20 → 240×48）", fitted.width, 240)
}
do {
    let width = 2000, height = 20
    let gray = [UInt8](repeating: 100, count: width * height)
    let fitted = PPOCRInputNormalizer.fit(gray: gray, width: width, height: height)
    eq("超宽图被压到上限 320", fitted.width, 320)
    check("仍是 8 的倍数", fitted.width % 8 == 0)
}
do {
    let width = 1, height = 48
    let gray = [UInt8](repeating: 50, count: width * height)
    let fitted = PPOCRInputNormalizer.fit(gray: gray, width: width, height: height)
    check("极窄图宽度至少 8", fitted.width >= 8, "\(fitted.width)")
}
do {
    let fitted = PPOCRInputNormalizer.fit(gray: [], width: 0, height: 0)
    check("空输入返回空", fitted.pixels.isEmpty && fitted.width == 0)
}
do {
    let width = 16, height = 8
    var gray = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height { for x in 0..<width { gray[y * width + x] = UInt8((x * 16) % 256) } }
    let fitted = PPOCRInputNormalizer.fit(gray: gray, width: width, height: height)
    check("缩放后有内容（不是全 0）", fitted.pixels.contains { $0 > 0 })
    check("缩放后仍是灰度值域", fitted.pixels.allSatisfy { $0 <= 255 })
}

print("\n═══════════════════════════════════════════════════════")
print("通过 \(passed)  失败 \(failed)")
exit(failed == 0 ? 0 : 1)
