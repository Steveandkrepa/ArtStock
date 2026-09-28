//
//  PackageParsing.swift
//  ArtAssist — 美术生的工具箱
//
//  收包裹：从一段文本里认出**快递单号**与**包裹里有什么**。
//
//  ── 为什么是"文本"而不是"接口" ───────────────────────────────
//  用户想要的是"输入快递单号时预先知道包裹里有什么"。这件事有三条路，
//  前两条走不通，所以这里是第三条：
//
//    ✗ **淘宝订单接口**：`api.taobao.com` 的订单接口只对**卖家**开放
//      （需要 ISV 应用 + 商家授权）。买家没有"读自己订单"的 API。
//      这不是没找对文档，是平台上就没有这个东西。
//    ✗ **物流轨迹接口**：它返回的是"已揽收/运输中/派送中"这类**节点**，
//      **不含商品内容**。而且实时查询要 key（快递100 要注册付费）。
//    ✓ **解析你手上已有的文本**：淘宝订单页复制出来的文字、
//      快递短信、或者**面单 OCR**（商家常把商品摘要印在面单上）。
//      这些文本里有商品名与数量，本地解析即可 —— 而且完全离线。
//
//  ── 这个文件为什么必须可测 ───────────────────────────────────
//  中文订单文本的格式五花八门，而解析错了的后果很具体：
//  把**手机号**、**淘宝订单号（19 位）**、**价格**当成快递单号，
//  用户点了"入库"才发现记错，而且他不会怀疑解析器。
//  所以这里全是纯函数，测试里塞了各种真实的脏文本。
//

import Foundation

// MARK: - 置信度

/// 判断的可信程度。
///
/// **刻意不用"对/错"二分。** 承运商识别这种事的本质是"猜"：
/// `SF` 开头基本可以确定是顺丰，而一串 13 位数字可能是韵达也可能是中通。
/// 把猜测标成事实，用户就会在错的时候以为是 App 坏了。
enum InferenceConfidence: String, Comparable, Sendable {
    /// 有明确前缀或通过了校验位算法。
    case certain
    /// 有明确的厂商前缀，但没有校验位可验。
    case likely
    /// 只靠位数与首几位猜的。
    case guess

    private var order: Int {
        switch self {
        case .certain: return 0
        case .likely: return 1
        case .guess: return 2
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }

    var displayName: String {
        switch self {
        case .certain: return "确定"
        case .likely: return "较可能"
        case .guess: return "猜测"
        }
    }
}

// MARK: - 快递单号

struct TrackingCandidate: Hashable, Sendable, Identifiable {
    var number: String
    /// 本地规则推出来的承运商。nil 表示认不出（不编一个出来）。
    var carrier: String?
    var confidence: InferenceConfidence
    /// 为什么这么判断 —— 显示给用户看，他才能判断该不该改。
    var evidence: String

    var id: String { number }
}

enum TrackingNumberParser {

    /// 万国邮联 S10 格式：2 位字母 + 9 位数字（末位是校验位）+ 2 位国家码。
    ///
    /// 这是**真正有国际标准**的一种快递单号格式（EMS / 邮政国际件），
    /// 而且校验位算法是公开的，所以这类能算到 `certain`。
    static func isValidUPU_S10(_ raw: String) -> Bool {
        let text = raw.uppercased()
        guard text.count == 13 else { return false }
        let chars = Array(text)
        guard chars[0].isLetter, chars[1].isLetter else { return false }
        guard chars[11].isLetter, chars[12].isLetter else { return false }
        guard (2...10).allSatisfy({ chars[$0].isNumber }) else { return false }

        // 校验位：前 8 位数字按权重 8,6,4,2,3,5,9,7 加权求和
        let weights = [8, 6, 4, 2, 3, 5, 9, 7]
        var sum = 0
        for (index, weight) in weights.enumerated() {
            guard let digit = chars[2 + index].wholeNumberValue else { return false }
            sum += digit * weight
        }
        var check = 11 - (sum % 11)
        if check == 10 { check = 0 }
        if check == 11 { check = 5 }
        guard let actual = chars[10].wholeNumberValue else { return false }
        return check == actual
    }

    /// 本地规则推断承运商。
    ///
    /// ⚠️ 这张表刻意做得**小**。承运商的首位规则又长又常改，
    /// 凭印象补全一张"看起来完整"的表，错的那几条会让用户不再信任这个功能。
    /// 所以：只放明确记得住的厂商前缀，其余靠位数给一个**标成猜测**的提示，
    /// 认不出就不填（界面让用户自己选）。
    static func inferCarrier(_ raw: String) -> (carrier: String, confidence: InferenceConfidence, evidence: String)? {
        let text = raw.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // ① 万国邮联 S10：有校验位，可以算到确定
        if text.count == 13, text.first?.isLetter == true {
            if isValidUPU_S10(text) {
                let country = String(text.suffix(2))
                let name = country == "CN" ? "中国邮政 / EMS" : "国际邮政（\(country)）"
                return (name, .certain, "符合万国邮联 S10 格式，校验位通过")
            }
        }

        // ② 厂商字母前缀
        let prefixed: [(prefixes: [String], carrier: String)] = [
            (["SF"], "顺丰速运"),
            (["JDV", "JDX", "JD"], "京东物流"),
            (["JT"], "极兔速递"),
            (["YT"], "圆通速递"),
            (["DOP"], "德邦快递"),
            (["EMS"], "中国邮政 / EMS"),
            (["STO"], "申通快递"),
            (["ZTO"], "中通快递"),
            (["YD"], "韵达速递"),
            (["DBL"], "德邦物流")
        ]
        for entry in prefixed {
            for prefix in entry.prefixes where text.hasPrefix(prefix) {
                // 前缀后面必须是数字，否则 "JDD" 这种也会命中
                let rest = text.dropFirst(prefix.count)
                guard !rest.isEmpty, rest.allSatisfy({ $0.isNumber }) else { continue }
                return (entry.carrier, .likely, "以 \(prefix) 开头")
            }
        }

        // ③ 纯数字：只能靠位数与首几位猜，标成猜测
        guard text.allSatisfy({ $0.isNumber }) else { return nil }
        switch text.count {
        case 12 where text.hasPrefix("75") || text.hasPrefix("76")
            || text.hasPrefix("78") || text.hasPrefix("68"):
            return ("中通快递", .guess, "12 位、\(text.prefix(2)) 开头，常见于中通")
        case 13 where text.hasPrefix("3") || text.hasPrefix("5")
            || text.hasPrefix("7") || text.hasPrefix("8") || text.hasPrefix("9"):
            return ("韵达速递", .guess, "13 位、\(text.prefix(1)) 开头，常见于韵达")
        default:
            return nil
        }
    }

    /// 一段文本里可能是快递单号的串。
    ///
    /// 关键在**排除**：淘宝订单号（16–20 位）、手机号（11 位、1 开头）、
    /// 价格（带小数点）、日期（8 位）都会混进来。
    /// 排除掉的比认出来的更重要 —— 认错一个，用户就会把订单号当单号记下来。
    static func candidates(in text: String) -> [TrackingCandidate] {
        var results: [TrackingCandidate] = []
        var seen = Set<String>()

        // 先按关键字把"订单号"这类明确不是快递单号的行摘掉
        let skipKeywords = ["订单号", "訂單號", "交易号", "支付宝", "手机号", "电话",
                            "收货人", "收货地址", "实付", "合计", "优惠", "运费"]

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if skipKeywords.contains(where: { line.contains($0) }) { continue }

            // 抽出字母数字串（保留字母，因为单号可能带前缀）
            for token in asciiTokens(in: line) {
                append(token, to: &results, seen: &seen)
            }

            // 再去掉空白与连字符切一次。
            //
            // 快递短信里常把单号**分段写**（`SF-1234 5678 90123`），
            // 按分隔符切会切成一堆太短的碎片，一个都认不出来。
            // 所以把空白与连字符抹掉后再切一遍。
            let compacted = line.replacingOccurrences(
                of: "[\\s\\-—–]", with: "", options: .regularExpression
            )
            if compacted != line {
                for token in asciiTokens(in: compacted) {
                    append(token, to: &results, seen: &seen)
                }
            }
        }

        // 已经能确定承运商的排前面
        return results.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence < rhs.confidence }
            return lhs.number < rhs.number
        }
    }

    /// 把一行拆成"可能构成单号"的 ASCII 字母数字串。
    ///
    /// ⚠️ **只收 ASCII。** 第一版用的是 `character.isLetter`，
    ///    而中日韩汉字在 Unicode 里也算 letter —— 于是
    ///    `单号SF1234567890123请查收`（没有分隔符时）会被当成**一个** token，
    ///    中文被并进单号里，还真能通过长度与"含数字"的检查。
    ///    快递单号只可能是 ASCII 字母数字，所以这里就该把范围收窄。
    private static func asciiTokens(in line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in line.uppercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                current.append(character)
            } else {
                if !current.isEmpty { tokens.append(current); current = "" }
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// 去重后追加一个候选。
    private static func append(
        _ token: String,
        to results: inout [TrackingCandidate],
        seen: inout Set<String>
    ) {
        guard let candidate = makeCandidate(token), !seen.contains(candidate.number) else { return }
        seen.insert(candidate.number)
        results.append(candidate)
    }

    /// 单个 token 是否是合理的单号。
    static func makeCandidate(_ token: String) -> TrackingCandidate? {
        let text = token.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        // 只允许 ASCII 字母数字，长度 8–20
        guard (8...20).contains(text.count) else { return nil }
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        // 必须含数字（纯字母不是单号）
        guard text.contains(where: { $0.isNumber }) else { return nil }
        // 不能全是数字且以 1 开头的 11 位 —— 那是手机号
        if text.count == 11, text.allSatisfy({ $0.isNumber }), text.hasPrefix("1") { return nil }
        // 纯数字超过 15 位基本是订单号而不是快递单号
        if text.allSatisfy({ $0.isNumber }), text.count > 15 { return nil }
        // 排除明显的年份+序号这种（如 20250612）
        if text.count == 8, text.allSatisfy({ $0.isNumber }) {
            let year = Int(text.prefix(4)) ?? 0
            if (2000...2100).contains(year) { return nil }
        }

        let inferred = inferCarrier(text)
        return TrackingCandidate(
            number: text,
            carrier: inferred?.carrier,
            confidence: inferred?.confidence ?? .guess,
            evidence: inferred?.evidence ?? "按格式看像个单号，但认不出是哪家"
        )
    }
}

// MARK: - 订单文本

struct ParsedPackageItem: Hashable, Sendable, Identifiable {
    /// 从文本里抽出来的商品名（原样保留，便于用户核对）。
    var name: String
    var quantity: Int
    /// 来源那一行，显示给用户看，方便他判断抽得对不对。
    var rawLine: String

    var id: String { "\(name)|\(quantity)|\(rawLine)" }
}

struct ParsedOrderText: Hashable, Sendable {
    var trackingNumber: String?
    var carrier: String?
    var items: [ParsedPackageItem]
    /// 抽出来的单号候选（界面可以让用户从里面挑）。
    var trackingCandidates: [TrackingCandidate]

    var isEmpty: Bool { items.isEmpty && trackingNumber == nil }
}

enum OrderTextParser {

    /// 明确不是商品名的行。
    ///
    /// 这些行里的数字如果被当成数量，就会生成一堆"订单号 x1"的假商品。
    private static let nonItemKeywords = [
        "订单号", "訂單號", "交易号", "交易號", "订单编号",
        "收货人", "收货地址", "地址", "电话", "手机号", "联系方式",
        "快递单号", "运单号", "物流单号", "物流公司", "承运",
        "实付", "应付", "合计", "总计", "优惠", "运费", "邮费", "店铺", "卖家",
        "下单时间", "付款时间", "发货时间", "创建时间", "订单状态", "交易状态",
        "支付宝", "花呗", "余额", "退款", "售后", "评价", "确认收货"
    ]

    /// 数量写法。中文订单文本里这几种最常见。
    private static let quantityPatterns: [String] = [
        "[xX×*]\\s*(\\d{1,3})\\b",
        "数量[:：]?\\s*(\\d{1,3})",
        "(\\d{1,3})\\s*(?:件|个|支|块|盒|包|瓶|卷|张|套|袋|只|根)",
        "共\\s*(\\d{1,3})\\s*(?:件|个|支|块|盒|包|瓶|卷|张|套|袋|只|根)",
        "^\\s*(\\d{1,3})\\s*$"
    ]

    /// 解析一段文本。
    ///
    /// - Parameter preferTracking: 用户已经填了单号时传进来，优先用它。
    static func parse(_ text: String, preferTracking: String? = nil) -> ParsedOrderText {
        let candidates = TrackingNumberParser.candidates(in: text)

        // 优先用用户明确给的；否则取置信度最高的候选
        var chosen: TrackingCandidate?
        if let preferTracking, !preferTracking.isEmpty {
            chosen = candidates.first { $0.number == preferTracking.uppercased() }
                ?? TrackingNumberParser.makeCandidate(preferTracking.uppercased())
        }
        if chosen == nil { chosen = candidates.first }

        var items: [ParsedPackageItem] = []
        var seenNames = Set<String>()

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.count >= 2 else { continue }
            guard !nonItemKeywords.contains(where: { line.contains($0) }) else { continue }
            // 整行就是这个单号 → 不是商品
            if let chosen, line.uppercased() == chosen.number { continue }

            guard let item = makeItem(from: line) else { continue }
            let key = item.name.lowercased()
            guard !seenNames.contains(key) else { continue }
            seenNames.insert(key)
            items.append(item)
        }

        return ParsedOrderText(
            trackingNumber: chosen?.number,
            carrier: chosen?.carrier,
            items: items,
            trackingCandidates: candidates
        )
    }

    /// 把一行变成商品。抽不出名字就返回 nil（宁可少认，不要塞垃圾）。
    static func makeItem(from line: String) -> ParsedPackageItem? {
        var working = line
        var quantity = 1
        var foundQuantity = false

        // 逐个模式试数量；试到一个就把它从名字里去掉
        for pattern in quantityPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(working.startIndex..., in: working)
            guard let match = regex.firstMatch(in: working, range: range),
                  match.numberOfRanges > 1,
                  let captured = Range(match.range(at: 1), in: working),
                  let value = Int(working[captured]) else { continue }
            quantity = max(1, min(999, value))
            foundQuantity = true
            if let whole = Range(match.range(at: 0), in: working) {
                working.removeSubrange(whole)
            }
            break
        }

        // 清掉价格、规格这类噪声
        working = stripNoise(working)
        let name = working.trimmingCharacters(in: .whitespacesAndNewlines)

        // 名字太短或太长都不像商品名
        guard name.count >= 2, name.count <= 80 else { return nil }
        // 名字里一个中日韩字或英文字母都没有 → 多半是数字/符号行
        guard name.contains(where: { $0.isLetter }) else { return nil }
        // 只有数量的行（"2"）不算
        if !foundQuantity, name.allSatisfy({ $0.isNumber }) { return nil }

        return ParsedPackageItem(name: name, quantity: quantity, rawLine: line)
    }

    /// 去掉价格、括号里的规格备注等噪声。
    private static func stripNoise(_ text: String) -> String {
        var result = text
        let patterns = [
            "[¥￥]\\s*\\d+(\\.\\d+)?",          // ¥12.34
            "\\d+(\\.\\d+)?\\s*元",             // 12.34 元
            "\\b\\d+(\\.\\d+)\\b",              // 裸小数（基本是价格）
            "[（(][^）)]{0,20}[）)]",           // 括号备注
            "[【\\[][^】\\]]{0,20}[】\\]]"       // 方括号备注
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern, with: " ", options: .regularExpression
            )
        }
        return result
    }
}

// MARK: - 匹配到库

/// 一个包裹里的条目匹配到你库里的什么。
enum PackageItemTarget: Hashable, Sendable {
    /// 匹配到一个颜料颜色。`kind` 是从商品名里看出来的补充装类型。
    case color(code: String, name: String, kind: RefillKind?)
    /// 匹配到一个已有耗材。
    case supply(name: String)
    /// 认不出是什么。
    case unmatched

    var displayName: String {
        switch self {
        case .color(_, let name, let kind):
            return kind == nil ? "颜料：\(name)" : "颜料：\(name)（\(kind!.displayName)）"
        case .supply(let name):
            return "耗材：\(name)"
        case .unmatched:
            return "没匹配到（入库时会新建）"
        }
    }
}

struct MatchedPackageItem: Hashable, Sendable, Identifiable {
    var item: ParsedPackageItem
    var target: PackageItemTarget
    /// 匹配得分 0…1，界面用它决定要不要提示"确认一下"。
    var score: Double

    var id: String { item.id }

    var needsConfirmation: Bool { score < 0.7 }
}

/// 已知的颜色与耗材（由调用方从数据库取出来喂进来，保持这个文件纯函数）。
struct PackageMatchCatalog: Sendable {
    struct Color: Sendable {
        var code: String
        var name: String
        var ciCode: String?
    }
    struct Supply: Sendable {
        var name: String
        var unit: String
    }
    var colors: [Color] = []
    var supplies: [Supply] = []

    /// 42 色预设 + 空耗材，用于测试与"库里还没有东西"的情况。
    static var presetOnly: PackageMatchCatalog {
        PackageMatchCatalog(
            colors: PresetColors.standard42.map {
                Color(code: PresetColors.code(forIndex: $0.index), name: $0.name, ciCode: $0.ciCode)
            },
            supplies: []
        )
    }
}

enum PackageItemMatcher {

    /// 从商品名里看补充装类型。
    ///
    /// 中文电商标题里这几个词很固定：
    ///   「替换装 / 色块 / 固体 / 块装」→ 直接替换装
    ///   「补充装 / 软管 / 挤压 / 挤出 / 袋装 / 瓶装」→ 挤出补充装
    /// 认不出时返回 nil，让用户在入库时自己选 —— 猜错类型会让库存记错地方。
    static func inferRefillKind(from name: String) -> RefillKind? {
        let text = name
        let panKeywords = ["替换装", "替换包", "色块", "固体", "块装", "预装块"]
        let squeezeKeywords = ["补充装", "软管", "挤压", "挤出", "袋装", "瓶装", "补充液", "罐装"]

        if panKeywords.contains(where: { text.contains($0) }) { return .pan }
        if squeezeKeywords.contains(where: { text.contains($0) }) { return .squeeze }
        return nil
    }

    /// 逐个匹配。
    static func match(
        items: [ParsedPackageItem],
        against catalog: PackageMatchCatalog
    ) -> [MatchedPackageItem] {
        items.map { item in
            let key = PaintLabelParser.nameKey(item.name)
            guard key.count >= 2 else {
                return MatchedPackageItem(item: item, target: .unmatched, score: 0)
            }

            var best: (target: PackageItemTarget, score: Double)?

            // ① 颜色：名字命中
            for color in catalog.colors {
                let colorKey = PaintLabelParser.nameKey(color.name)
                guard colorKey.count >= 2 else { continue }
                let (raw, _) = PaintLabelParser.similarity(lineKey: key, nameKey: colorKey)
                guard raw > 0 else { continue }
                if best == nil || raw > best!.score {
                    best = (.color(code: color.code, name: color.name,
                                   kind: inferRefillKind(from: item.name)), raw)
                }
            }

            // ② 颜色：标准号命中（更硬，优先）
            for color in catalog.colors {
                guard let ci = color.ciCode, !ci.isEmpty else { continue }
                if item.name.uppercased().contains(ci.uppercased()) {
                    best = (.color(code: color.code, name: color.name,
                                   kind: inferRefillKind(from: item.name)), 1.0)
                }
            }

            // ③ 耗材：名字命中
            for supply in catalog.supplies {
                let supplyKey = PaintLabelParser.nameKey(supply.name)
                guard supplyKey.count >= 2 else { continue }
                // 耗材名通常更短，用"互相包含 + 2-gram"两档
                var score = 0.0
                if key.contains(supplyKey) { score = 0.75 }
                else {
                    let dice = PaintLabelParser.diceCoefficient(key, supplyKey)
                    if dice >= 0.5 { score = dice * 0.8 }
                }
                if score > 0, best == nil || score > best!.score {
                    best = (.supply(name: supply.name), score)
                }
            }

            guard let best else {
                return MatchedPackageItem(item: item, target: .unmatched, score: 0)
            }
            return MatchedPackageItem(item: item, target: best.target, score: best.score)
        }
    }
}
