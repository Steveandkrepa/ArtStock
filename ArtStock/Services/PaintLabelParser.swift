//
//  PaintLabelParser.swift
//  ArtAssist — 美术生的工具箱
//
//  把 OCR 读到的包装文字，变成一条颜色草稿。
//
//  ── 为什么需要它 ─────────────────────────────────────────────
//  真实反馈：「二维码搜索有个致命 bug，所有颜料的条码都是一样的」。
//
//  这不是 bug，是**中国颜料包装的现实**：
//    · 管子上印的二维码，99% 是品牌的公众号/官网码 —— 同一个品牌
//      所有颜色、所有型号印的都是**同一张图**。它不携带任何产品信息。
//    · 管子上真正唯一的是 **EAN-13 零售条码**（如果有的话）。
//    · 而廉价水粉套装经常连条码都没有，只有**印上去的字**：
//      「群青」「钛白」「深红」，有些还印「PW6」「PB29」这样的颜料索引号。
//
//  所以正确的路子不是"扫得更准"，而是**认字**：
//  管子上最可靠的产品信息，本来就是印出来的颜色名。
//
//  ── 设计约束 ─────────────────────────────────────────────────
//  这个文件**只用 Foundation**，不 import Vision / AVFoundation。
//  这样它能在 macOS 上直接编译运行、用真实样例做回归测试 ——
//  OCR 的准确率没法离线测，但"文字 → 颜色"的推断逻辑必须测得动。
//

import Foundation

// MARK: - 输入

/// OCR 认出来的一行字。
struct PaintLabelLine: Hashable, Sendable {
    /// 识别出的文本。
    var text: String
    /// Vision 给的置信度 0…1。
    var confidence: Double

    init(text: String, confidence: Double = 1.0) {
        self.text = text
        self.confidence = confidence
    }
}

/// 用来比对的已知颜色（颜色库 + 42 色预设）。
struct KnownLabelColor: Hashable, Sendable {
    var code: String
    var name: String
    var ciCode: String?
    var hex: String?

    init(code: String, name: String, ciCode: String? = nil, hex: String? = nil) {
        self.code = code
        self.name = name
        self.ciCode = ciCode
        self.hex = hex
    }
}

// MARK: - 输出

/// OCR 推断出来的颜色草稿。
struct PaintLabelDraft: Hashable, Sendable, Identifiable {

    var id: String { rawText }

    /// OCR 原文（所有行拼起来），保留下来便于用户核对与溯源。
    var rawText: String
    var lines: [PaintLabelLine]

    /// 认出来的颜色名（可能是模糊匹配的候选）。
    var colorName: String?
    /// 认出来的 Colour Index 颜料标准号，例如 `PW6`。
    var ciCode: String?
    /// 认出来的色号 / 商品编号。
    var productCode: String?
    var brand: String?
    var series: String?

    /// 匹配到的已知颜色（颜色库或预设）。有值就意味着"这个颜色我认得"。
    var matchedCode: String?
    var matchedName: String?
    var matchedHex: String?
    var matchScore: Double
    var matchKind: MatchKind

    /// 整体置信度 0…1。
    var confidence: Double
    var warnings: [String]

    enum MatchKind: String, Hashable, Sendable {
        /// 文字与颜色名完全一致。
        case exact
        /// 文字里包含颜色名，或颜色名包含文字（OCR 截断）。
        case contains
        /// 靠 2-gram 相似度猜的，需要用户确认。
        case fuzzy
        /// 靠 Colour Index 标准号对上的。
        case ciCode
        /// 没匹配上。
        case none

        var displayName: String {
            switch self {
            case .exact: return "完全匹配"
            case .contains: return "匹配到颜色名"
            case .fuzzy: return "相似匹配"
            case .ciCode: return "按颜料标准号匹配"
            case .none: return "没有匹配"
            }
        }
    }

    /// 够了 —— 至少认出了颜色名或颜料标准号。
    var hasColor: Bool {
        colorName != nil || ciCode != nil
    }

    /// 匹配到已知颜色才算"直接能用"。
    var isConfident: Bool {
        switch matchKind {
        case .exact, .ciCode: return true
        // 0.70 ≈ 颜色名至少占整行的 1/3。
        // 整行连写（2 字色名夹在 14 字里）拿 0.61，会走"请确认"这条路 ——
        // 那是诚实的：从长行里挑出来的名字，值得你扫一眼。
        case .contains: return matchScore >= 0.70
        case .fuzzy, .none: return false
        }
    }

    /// 入库时建议用的色号。
    ///
    /// 匹配到已知颜色时**直接复用它的色号** —— 这样 OCR 认出的「群青」
    /// 会落到预设的 `PRESET-35` 上，跟盒子里 F5 格那个颜色是同一条记录，
    /// 而不是又建一个重名的新颜色。
    var suggestedCode: String {
        if let matchedCode { return matchedCode }
        if let colorName, !colorName.isEmpty {
            let slug = PaintLabelParser.slug(colorName)
            if !slug.isEmpty { return "OCR-\(slug)" }
        }
        return ""
    }

    var suggestedName: String {
        if let matchedName { return matchedName }
        if let colorName, !colorName.isEmpty { return colorName }
        return ""
    }

    var suggestedHex: String? {
        matchedHex
    }

    /// 界面上一句话说明这次读到了什么。
    var summary: String {
        if let matchedName, matchKind == .exact || matchKind == .ciCode {
            return "读到「\(matchedName)」，颜色库里就有这个颜色"
        }
        if let matchedName {
            return "可能是「\(matchedName)」（\(matchKind.displayName)），确认一下"
        }
        if let colorName {
            return "读到「\(colorName)」，颜色库里还没有，可以新建"
        }
        if let ciCode {
            return "读到颜料标准号 \(ciCode)"
        }
        if let productCode {
            return "只读到编号 \(productCode)，没认出颜色名"
        }
        return "没读到可用的颜色信息"
    }
}

// MARK: - 解析器

enum PaintLabelParser {

    // MARK: 已知品牌

    /// 常见美术颜料品牌。命中就用它当 brand。
    ///
    /// 刻意只放**美术材料**品牌 —— 放通用词会导致误判。
    static let brandKeywords: [String] = [
        "温莎牛顿", "WINSORNEWTON", "WINSOR&NEWTON", "荷尔拜因", "HOLBEIN",
        "贝碧欧", "PEBEO", "史明克", "SCHMINCKE", "梵高", "VANGOGH",
        "伦勃朗", "REMBRANDT", "白夜", "WHITENIGHTS", "鲁本斯", "RUBENS",
        "蒙玛特", "MONTMARTE", "马利", "MARIES", "米娅", "MIYA",
        "樱花", "SAKURA", "辉柏嘉", "FABERCASTELL", "美邦", "MEIBANG",
        "青竹", "得力", "DELI", "晨光", "M&G", "马蒂尼", "凤凰", "PHOENIX",
        "奥文", "ALVIN", "康大", "KANGDA", "泰伦斯", "TALENS", "乔琴", "DALERROWNEY"
    ]

    /// 等级 / 系列词。
    static let seriesKeywords: [String] = [
        "艺术家级", "学院级", "学生级", "专业级", "大师级", "入门级", "儿童级",
        "ARTIST", "STUDENT", "ACADEMIC", "PROFESSIONAL", "MASTER"
    ]

    /// Colour Index 的类别字母。`Bk`/`Br` 必须排在单字母前。
    private static let ciCategories = ["BK", "BR", "W", "Y", "O", "R", "V", "B", "G", "N", "M"]

    // MARK: 入口

    /// 从 OCR 行里推断颜色。
    /// - Parameter known: 已知颜色（颜色库 + 预设）。传空数组也能用，只是没有匹配。
    static func parse(lines: [PaintLabelLine], known: [KnownLabelColor] = []) -> PaintLabelDraft {
        let usable = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let rawText = usable.map(\.text).joined(separator: "\n")
        let joined = usable.map(\.text).joined(separator: " ")

        var warnings: [String] = []

        // ── 1. Colour Index 标准号（最硬的证据，先找它）──
        let ciCode = extractCICode(from: joined)

        // ── 2. 颜色名匹配 ──
        let nameMatch = bestNameMatch(in: usable, known: known)

        // ── 3. 按 C.I. 号匹配（比模糊认字可靠得多）──
        var matchKind: PaintLabelDraft.MatchKind = .none
        var matchScore: Double = 0
        var matched: KnownLabelColor?
        var resolvedName = nameMatch?.name

        if let ciCode {
            // ⚠️ 两边都要 uppercased —— 提取出来的是规范写法 `PBr7`，
            //    而比对时可能拿到 `PBR7`。少一次 uppercased 会让整条 CI 匹配静默失效。
            let ciKey = ciCode.uppercased()
            let candidates = known.filter { $0.ciCode?.uppercased() == ciKey }
            if candidates.count == 1 {
                matched = candidates[0]
                matchKind = .ciCode
                matchScore = 1.0
                resolvedName = candidates[0].name
            } else if candidates.count > 1 {
                // 同一个颜料号对应多个颜色名（品牌命名不同），优先用文字里也出现过的那个。
                let byName = candidates.first { candidate in
                    nameMatch?.name == candidate.name
                }
                matched = byName ?? candidates[0]
                matchKind = .ciCode
                matchScore = byName != nil ? 1.0 : 0.85
                resolvedName = matched?.name
                if byName == nil {
                    warnings.append("\(ciCode) 在颜色库里有 \(candidates.count) 个颜色，先按「\(candidates[0].name)」处理，请确认。")
                }
            }
        }

        if matched == nil, let nameMatch {
            matched = nameMatch.color
            matchKind = nameMatch.kind
            matchScore = nameMatch.score
        }

        // 认不出已知颜色时，退一步挑一个"最像颜色名"的行。
        // 这样用户那盒里 42 色之外的颜色（孔雀绿、天青蓝…）也能建进来，
        // 而不是每次都让他手打。
        if resolvedName == nil, ciCode == nil {
            resolvedName = candidateName(in: usable)
        }

        // ── 4. 编号与品牌 ──
        let productCode = extractProductCode(from: joined)
        let brand = brandKeywords.first { normalizeAlphanumeric(joined).contains(normalizeAlphanumeric($0)) }
        let series = seriesKeywords.first { normalizeAlphanumeric(joined).contains(normalizeAlphanumeric($0)) }

        // ── 5. 置信度 ──
        let baseConfidence = usable.map(\.confidence).max() ?? 0
        var confidence = matchScore * 0.7 + baseConfidence * 0.3
        if case .fuzzy = matchKind { confidence *= 0.7 }
        if matched == nil { confidence = min(confidence, 0.35) }

        // ── 6. 提示 ──
        if resolvedName == nil, ciCode == nil {
            warnings.append("没认出颜色名。把镜头再靠近一点，让颜色名占满画面；或者直接手动选颜色。")
        }
        if matchKind == .fuzzy, let matched {
            warnings.append("「\(matched.name)」是按字形相似猜的，不一定准，入库前确认一下。")
        }
        if matched == nil, let resolvedName {
            warnings.append("颜色库里还没有「\(resolvedName)」，入库会新建一条。")
        }
        if let nameMatch, nameMatch.runnerUpScore >= nameMatch.score - 0.08, nameMatch.runnerUpScore >= 0.6 {
            warnings.append("画面里可能不止一个颜色名，只取了匹配度最高的「\(nameMatch.name)」。")
        }

        return PaintLabelDraft(
            rawText: rawText,
            lines: usable,
            colorName: resolvedName,
            ciCode: ciCode,
            productCode: productCode,
            brand: brand,
            series: series,
            matchedCode: matched?.code,
            matchedName: matched?.name,
            matchedHex: matched?.hex,
            matchScore: matchScore,
            matchKind: matchKind,
            confidence: max(0, min(1, confidence)),
            warnings: warnings
        )
    }

    /// 便利入口：直接给一段多行文本（测试与手输都用它）。
    static func parse(text: String, known: [KnownLabelColor] = []) -> PaintLabelDraft {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { PaintLabelLine(text: String($0)) }
        return parse(lines: lines, known: known)
    }

    /// 42 色预设作为"已知颜色"。
    static var presetKnown: [KnownLabelColor] {
        PresetColors.standard42.map {
            KnownLabelColor(
                code: PresetColors.code(forIndex: $0.index),
                name: $0.name,
                ciCode: $0.ciCode,
                hex: $0.hex
            )
        }
    }

    // MARK: 编号 / 标准号提取

    /// 提取 Colour Index 号，例如 `PW6`、`P.B.29`、`PR 108`、`钛白PW6`。
    ///
    /// 要覆盖的写法比想象中多（都是真机上会遇到的）：
    ///     `PW6`      连写
    ///     `P.W.6`    点分隔
    ///     `P.B.29`   类别是双字母时点更多
    ///     `PR 106`   空格分隔
    ///     `钛白PW6`  中文与标准号粘连（OCR 常见）
    ///     `PBr7`     双字母类别（棕）
    ///
    /// **必须防假阳性**，否则 `HAPPY2024` 里能切出 `PY202`。
    /// 做法：只保留 ASCII 字符（把中文整段丢掉），然后两条路都试 ——
    ///   ① 按空格/标点切词，整词匹配
    ///   ② 把所有分隔符去掉，找 `P<类别><1-3位数字>`，但要求左边不是字母数字、右边不是数字
    /// 宁可少认，不可认错。
    static func extractCICode(from text: String) -> String? {
        // 只留 ASCII：中文汉字会被整段剔除，避免"钛白PW6"被当成一个整词。
        let halfWidth = String(text.map(toHalfWidth)).uppercased()
        let ascii = String(halfWidth.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" || $0 == " ") })
        guard ascii.contains("P") else { return nil }

        // ① 切词匹配
        let stripped = ascii.replacingOccurrences(of: ".", with: "")
        for token in stripped.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if let code = canonicalCICode(String(token)) { return code }
        }

        // ② 去掉所有分隔符后按边界找（覆盖 `PR 106` 这种写法）
        let compact = String(ascii.filter { $0.isLetter || $0.isNumber })
        let characters = Array(compact)
        var index = 0
        while index < characters.count {
            guard characters[index] == "P" else { index += 1; continue }
            // 左边不能是字母数字，否则 "HAPPY2024" 里的 PY202 会被误认
            if index > 0, characters[index - 1].isLetter || characters[index - 1].isNumber {
                index += 1
                continue
            }
            var end = index
            while end < characters.count, characters[end].isLetter || characters[end].isNumber { end += 1 }
            // 右边不能紧跟数字（说明数字比 3 位长）
            if end < characters.count, characters[end].isNumber { index += 1; continue }
            if let code = canonicalCICode(String(characters[index..<end])) { return code }
            index += 1
        }
        return nil
    }

    /// 把 `PW6` / `PBR7` / `PB29` 这样的整词规范成标准写法；不是标准号就返回 nil。
    private static func canonicalCICode(_ token: String) -> String? {
        guard token.hasPrefix("P"), (3...5).contains(token.count) else { return nil }
        let body = token.dropFirst()
        // 双字母类别（Br / Bk）要排在单字母前，否则 B 会先匹配掉 Br。
        for category in ciCategories where body.hasPrefix(category) {
            let digits = body.dropFirst(category.count)
            guard (1...3).contains(digits.count), digits.allSatisfy(\.isNumber) else { continue }
            // 前导 0 不是合法写法（PW06）
            guard digits.first != "0" else { continue }
            return "P" + category.prefix(1) + category.dropFirst().lowercased() + digits
        }
        return nil
    }

    /// 提取色号 / 商品编号。
    ///
    /// 优先级：显式关键词 > `#` 前缀 > 独立的 8/12/13 位数字（EAN）。
    static func extractProductCode(from text: String) -> String? {
        // 注意：这里**不能**用 normalizeAlphanumeric —— 它会把 `#` 和 `-` 删掉，
        // 于是 `#108` 认不出来、`M-35` 变成 `M35`。编号的标点是有意义的。
        let source = codeSource(text)

        // 1) 关键词后面跟的编号
        let keywordPattern = "(?:NO|编号|货号|色号|型号|MODEL|ITEM|ITEMNO|ARTNO|COLORNO)[\\s.:：]*([A-Z0-9][A-Z0-9\\-]{0,11})"
        if let match = firstCapture(pattern: keywordPattern, in: source) {
            let code = match.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if code.count >= 1, code.contains(where: \.isNumber) { return code }
        }

        // 2) # 后面的编号
        if let match = firstCapture(pattern: "#([A-Z0-9][A-Z0-9\\-]{0,11})", in: source) {
            if match.contains(where: \.isNumber) { return match }
        }

        // 3) 独立的 EAN / UPC 数字串（8 / 12 / 13 位）
        let digitsOnly = source.split(whereSeparator: { !$0.isNumber })
        for token in digitsOnly where [8, 12, 13].contains(token.count) {
            return String(token)
        }

        return nil
    }

    /// 编号提取专用的规范化：全角转半角、转大写、保留 `#` 与 `-`、折叠空白。
    static func codeSource(_ text: String) -> String {
        var out = ""
        for character in String(text.map(toHalfWidth)).uppercased() {
            if character.isLetter || character.isNumber || character == "#" || character == "-" {
                out.append(character)
            } else {
                out.append(" ")
            }
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    private static func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    // MARK: 颜色名匹配

    struct NameMatch {
        var color: KnownLabelColor?
        var name: String
        var score: Double
        var kind: PaintLabelDraft.MatchKind
        var runnerUpScore: Double
    }

    /// 不该被当成颜色名的单字。OCR 在包装上最常见的就是这些。
    static let singleCharacterStopList: Set<Character> = [
        "色", "号", "牌", "装", "克", "毫", "升", "净", "含", "量", "型", "支", "瓶",
        "盒", "套", "系", "列", "级", "品", "牌", "产", "地", "厂", "公", "司", "有",
        "限", "说", "明", "成", "分", "保", "质", "期", "日", "水", "用", "法", "注",
        "意", "事", "项", "标", "准", "编", "货", "规", "格", "重", "容"
    ]

    /// 在一堆 OCR 行里找出最像颜色名的那一行。
    static func bestNameMatch(in lines: [PaintLabelLine], known: [KnownLabelColor]) -> NameMatch? {
        guard !known.isEmpty else { return nil }

        var best: (color: KnownLabelColor, score: Double, kind: PaintLabelDraft.MatchKind)?
        var secondBest: Double = 0

        for line in lines {
            let lineKey = nameKey(line.text)
            // 允许单字行（「群」可能是「群青」被截断），但把包装上的高频单字排除掉。
            guard !lineKey.isEmpty else { continue }
            if lineKey.count == 1, let first = lineKey.first, singleCharacterStopList.contains(first) { continue }

            for color in known {
                let nameKeyValue = nameKey(color.name)
                guard nameKeyValue.count >= 2 else { continue }

                let (score, kind) = similarity(lineKey: lineKey, nameKey: nameKeyValue)
                guard score > 0.45 else { continue }

                if let current = best {
                    if score > current.score {
                        secondBest = max(secondBest, current.score)
                        best = (color, score, kind)
                    } else {
                        secondBest = max(secondBest, score)
                    }
                } else {
                    best = (color, score, kind)
                }
            }
        }

        guard let best else { return nil }
        return NameMatch(
            color: best.color,
            name: best.color.name,
            score: best.score,
            kind: best.kind,
            runnerUpScore: secondBest
        )
    }

    /// 单行 vs 单个颜色名。
    static func similarity(lineKey: String, nameKey: String) -> (Double, PaintLabelDraft.MatchKind) {
        if lineKey == nameKey { return (1.0, .exact) }

        if lineKey.contains(nameKey) {
            // 名字在行里（「马利牌 群青 5ml 上海马利画材」这种整行连写也走这里）。
            //
            // 打分只用一个量：**名字占整行的比例**。
            // 它同时表达了"名字有多具体"和"这行有多少别的噪声"，
            // 比"行比名字长多少"这种绝对长度惩罚稳 —— 后者会把真实排版误杀（测试抓到过）。
            let coverage = Double(nameKey.count) / Double(lineKey.count)
            return (0.55 + 0.45 * coverage, .contains)
        }

        if nameKey.contains(lineKey) {
            // OCR 只读到一部分字（截断、被遮挡、字太小）。
            // 这类**永远不给高置信** —— 读到一个「群」字就断言是「群青」太武断。
            let coverage = Double(lineKey.count) / Double(nameKey.count)
            if coverage >= 0.5 { return (0.40 + 0.35 * coverage, .contains) }
        }

        // 2-gram 相似度兜底：只认"很像"的，避免把无关的字凑成颜色。
        let dice = diceCoefficient(lineKey, nameKey)
        if dice >= 0.6 { return (0.55 * dice + 0.2, .fuzzy) }

        return (0, .none)
    }

    /// 二元组 Dice 系数，对中文与英文都适用。
    static func diceCoefficient(_ lhs: String, _ rhs: String) -> Double {
        let a = bigrams(lhs)
        let b = bigrams(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }

        var remaining = b
        var hits = 0
        for gram in a {
            if let index = remaining.firstIndex(of: gram) {
                remaining.remove(at: index)
                hits += 1
            }
        }
        return 2 * Double(hits) / Double(a.count + b.count)
    }

    private static func bigrams(_ text: String) -> [String] {
        let characters = Array(text)
        guard characters.count >= 2 else { return characters.isEmpty ? [] : [text] }
        return (0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) }
    }

    // MARK: 颜色名候选（库里没有的颜色）

    /// 颜色名里常见的字。用来判断"这行像不像颜色名"。
    static let colorishCharacters: Set<Character> = Set("红黄蓝绿青紫黑白灰褐赭粉橙金银驼肉豆玫丁香草墨橄榄苹果柠檬群钴普湖天海翠朱丹绯绛黛碧棕咖啡米杏桃葡栗陶砖砂土".map { $0 })

    /// 包装上一定不是颜色名的词。
    static let labelStopWords: [String] = [
        "净含量", "生产日期", "保质期", "有效期", "成分", "说明书", "注意事项", "使用方法",
        "执行标准", "生产厂家", "厂名", "厂址", "地址", "电话", "网址", "产地", "型号",
        "货号", "批号", "条码", "二维码", "合格证", "检验", "警告", "儿童", "注意",
        "毫升", "克", "千克", "颜料", "水粉", "丙烯", "国画", "油画", "广告画", "画材",
        "美术", "用品", "有限公司", "有限", "公司"
    ]

    /// 在没有匹配到已知颜色时，挑一个最像颜色名的行。
    ///
    /// 判据（按重要性）：
    ///   1. 不含包装上的固定文案词（净含量、生产日期、有限公司…）
    ///   2. 含有颜色字（红黄蓝绿青紫黑白灰…）
    ///   3. 长度 2–6 字最像色名
    ///   4. OCR 置信度高
    static func candidateName(in lines: [PaintLabelLine]) -> String? {
        var best: (text: String, score: Double)?

        for line in lines {
            let raw = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }

            let compact = String(raw.filter { !$0.isWhitespace })
            let key = normalizeAlphanumeric(compact)
            guard (2...6).contains(key.count) else { continue }

            // 只要中日韩文字，别的都排除（编号、英文说明不是色名）
            let isCJK = compact.allSatisfy { $0.unicodeScalars.allSatisfy { scalar in
                (0x3400...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
            } }
            guard isCJK else { continue }

            let lowered = raw
            guard !labelStopWords.contains(where: { lowered.contains($0) }) else { continue }

            let colorHits = key.filter { colorishCharacters.contains($0) }.count
            guard colorHits > 0 else { continue }

            var score = Double(colorHits) * 0.3
            // 2 字和 3 字的色名最常见
            score += key.count == 3 ? 0.35 : (key.count == 2 ? 0.3 : 0.1)
            score += line.confidence * 0.25
            // 越长越不像色名
            score -= Double(max(0, key.count - 3)) * 0.15

            if best == nil || score > best!.score {
                best = (compact, score)
            }
        }

        return best?.text
    }

    // MARK: 文本规范化

    /// 颜色名比对用的 key：全角转半角、去空格与标点、转大写。
    static func nameKey(_ text: String) -> String {
        var key = normalizeAlphanumeric(text)
        // 「深红色」= 「深红」，所以去掉结尾的「色」。
        // 但**去掉之后至少要剩 2 个字** —— 否则「肉色」会变成「肉」、「黑色」会变成「黑」，
        // 长度不够反而匹配不上自己（这是测试抓出来的真实 bug）。
        if key.hasSuffix("色"), key.count > 2 {
            key.removeLast()
        }
        return key
    }

    /// 全角转半角 → 去所有非字母数字 → 转大写。
    static func normalizeAlphanumeric(_ text: String) -> String {
        String(text.map(Self.toHalfWidth).filter { $0.isLetter || $0.isNumber })
            .uppercased()
    }

    /// 生成可读的色号片段。
    static func slug(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var out = ""
        for character in trimmed {
            if character.isLetter || character.isNumber {
                out.append(character)
            } else if !out.hasSuffix("-") {
                out.append("-")
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// 全角字符 → 半角。
    static func toHalfWidth(_ character: Character) -> Character {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else { return character }
        switch scalar.value {
        case 0x3000: return " "
        case 0xFF01...0xFF5E:
            guard let converted = Unicode.Scalar(scalar.value - 0xFEE0) else { return character }
            return Character(converted)
        default:
            return character
        }
    }
}
