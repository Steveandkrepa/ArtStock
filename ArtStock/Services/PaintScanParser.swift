//
//  PaintScanParser.swift
//  ArtAssist — 美术生的工具箱
//
//  扫颜料包装上的码 → 解析出颜色信息。
//
//  ── 现实情况（决定了这里的设计）──────────────────────────────
//  颜料管/颜料块包装上印的多半是 **EAN-13 之类的零售条码**，那串数字本身
//  不携带任何颜色信息 —— 它只是厂家的商品编号。真正带颜色信息的只有：
//    · 部分品牌印的二维码（内含 JSON 或 URL 参数）
//    · 用户自己贴的标签
//  所以解析器的定位是：
//    「能拿到多少算多少」—— 拿不到颜色就让用户自己选，
//    但**色号一定会填好**，这是扫码最确定、也是最有用的产出。
//
//  ── 完全离线 ────────────────────────────────────────────────
//  不联网、不查库、不上传。所有解析都在本机完成。
//
//  本文件只依赖 Foundation，因此有独立的回归测试
//  （Tests/ScanParserTests，见 scripts/run-scan-tests.sh）。
//

import Foundation

// MARK: - 解析来源

enum PayloadSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case json
    case keyValue
    case url
    case gs1
    /// 零售条码/纯文本：只有一串编号。
    case plain

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .json: return "JSON 载荷"
        case .keyValue: return "键值文本"
        case .url: return "链接载荷"
        case .gs1: return "GS1 应用标识"
        case .plain: return "零售条码 / 纯文本"
        }
    }

    var symbolName: String {
        switch self {
        case .json: return "curlybraces"
        case .keyValue: return "list.bullet.rectangle"
        case .url: return "link"
        case .gs1: return "barcode"
        case .plain: return "textformat"
        }
    }

    /// 这个来源通常能给出多少信息。用于给用户预期。
    var automationHint: String {
        switch self {
        case .json: return "字段最全，通常能直接得到颜色名与色值"
        case .url: return "从链接参数里提取字段"
        case .keyValue: return "从键值对里提取字段"
        case .gs1: return "标准条码，一般只有商品编号与批次"
        case .plain: return "只有一串编号，颜色需要你手动指定"
        }
    }
}

// MARK: - 符号类型

/// 条码符号类型的展示映射。
///
/// 只依赖原始字符串，避免模型层 import AVFoundation。
enum ScanSymbology {

    static func displayName(forRawValue raw: String) -> String {
        switch raw {
        case "org.iso.QRCode": return "QR 码"
        case "org.gs1.EAN-13": return "EAN-13 条码"
        case "org.gs1.EAN-8": return "EAN-8 条码"
        case "org.gs1.UPC-E": return "UPC-E 条码"
        case "org.iso.Code128": return "Code 128"
        case "org.iso.Code39": return "Code 39"
        case "org.iso.Code93": return "Code 93"
        case "org.iso.ITF14": return "ITF-14"
        case "org.iso.PDF417": return "PDF417"
        case "org.iso.Aztec": return "Aztec"
        case "org.iso.DataMatrix": return "Data Matrix"
        default: return raw.isEmpty ? "未知" : raw
        }
    }

    /// 是否为零售条码（这类码基本只有编号，没有颜色信息）。
    static func isRetailBarcode(_ raw: String) -> Bool {
        raw.hasPrefix("org.gs1.") || raw == "org.iso.ITF14"
    }

    /// 这个二维码是不是"品牌级"的（公众号 / 官网 / 电商店铺），而不是产品级。
    ///
    /// 判据：
    ///   · 域名是已知的社交 / 电商平台
    ///   · 或者路径只有根、也没有任何查询参数 —— 产品级二维码通常会把
    ///     型号或序列号放在路径或参数里，什么都没有的多半是官网首页
    static func isBrandMarketingURL(_ payload: String) -> Bool {
        guard let url = URL(string: payload),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }

        let host = (url.host ?? "").lowercased()
        let marketingHosts = [
            "weixin.qq.com", "mp.weixin.qq.com", "wechat.com", "weibo.com", "weibo.cn",
            "douyin.com", "xiaohongshu.com", "xhslink.com", "taobao.com", "tmall.com",
            "jd.com", "1688.com", "youku.com", "bilibili.com", "qq.com", "sohu.com"
        ]
        if marketingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return true
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let query = url.query ?? ""
        return path.isEmpty && query.isEmpty
    }

    /// 是否为本应用自己生成的标签。
    static func isOwnLabel(payload: String) -> Bool {
        let lowered = payload.lowercased()
        if lowered.hasPrefix("artstock://") { return true }
        return lowered.contains("\"generator\":\"artstock\"")
            || lowered.contains("\"generator\": \"artstock\"")
    }
}

// MARK: - 解析结果

/// 从码里解析出的颜色草稿。
///
/// **所有颜色字段都是可选的** —— 扫到零售条码时通常只有 code，
/// 这是正常的、也是预期内的，界面会引导用户补上颜色。
struct PaintColorDraft: Hashable, Sendable, Identifiable {

    var id: String { "\(symbologyRaw)|\(rawPayload)" }

    var rawPayload: String
    var symbologyRaw: String
    var source: PayloadSource

    /// 色号 / 商品编号。扫码最确定的产出，正常情况下一定有值。
    var code: String

    var name: String?
    var brand: String?
    var series: String?
    /// 颜色值 `#RRGGBB`。
    var hex: String?

    /// 成功提取到的字段数量（不含 code）。
    var fieldCount: Int
    var warnings: [String]
    var isOwnLabel: Bool

    /// 这个码**可能被好几个颜色共用**，所以不能拿它当颜色身份。
    ///
    /// 真实反馈：「颜料本身不同颜色的条形码都是一样的，不是每个颜色一个条形码」。
    /// 一维零售条码在国产颜料上经常整批共用一个 —— 可能是套装码、
    /// 也可能是厂家就没给每个颜色单独申请。
    ///
    /// 一旦按条码建了第一条颜色，再扫同一盒里别的颜色就会撞上唯一约束，
    /// 第二个颜色**永远进不来**。所以这类码只能当"批次线索"，
    /// 真正的身份必须来自颜色名（认字）或用户自己填。
    ///
    /// 一维零售条码默认按"可能共用"处理 —— 由用户在同名时复用已有颜色兜底，
    /// 比赌它唯一然后卡死要好。
    /// 默认 false —— 这样 memberwise init 带默认参数，
    /// 已有的构造点不用逐个改（少改一处就少一个漏填的机会）。
    var payloadMayBeShared: Bool = false

    /// 用颜色名生成色号。`payloadMayBeShared` 为真时用它替代条码。
    func nameBasedCode(_ name: String) -> String {
        let slug = PaintLabelParser.slug(name)
        return slug.isEmpty ? code : "NAME-\(slug)"
    }

    var symbologyName: String {
        ScanSymbology.displayName(forRawValue: symbologyRaw)
    }

    /// 是不是零售条码 —— 决定界面上要不要强调"颜色需要你自己选"。
    var isRetailCode: Bool {
        ScanSymbology.isRetailBarcode(symbologyRaw)
    }

    /// 是否解析到了颜色本身。
    var hasColor: Bool {
        if let hex, !hex.isEmpty { return true }
        return false
    }

    /// 入库时建议用的名称。
    var suggestedName: String {
        if let name, !name.isEmpty { return name }
        if let series, !series.isEmpty { return series }
        return code
    }

    /// 解析质量描述，一句话告诉用户这次扫到了什么。
    var qualitySummary: String {
        if hasColor, let name, !name.isEmpty {
            return "识别到「\(name)」及颜色值，可直接入库"
        }
        if hasColor {
            return "识别到颜色值，名称建议补一下"
        }
        if fieldCount > 0 {
            return "识别到 \(fieldCount) 个字段，颜色需要你选一下"
        }
        if isRetailCode {
            return "这是零售条码，只有编号 —— 颜色请手动选"
        }
        if payloadMayBeShared {
            return "这个条码可能被多个颜色共用，色号建议用颜色名"
        }
        return "只识别到编号，颜色请手动选"
    }
}

// MARK: - 解析器

enum PaintScanParser {

    /// 解析扫码得到的原始内容。
    /// - Parameters:
    ///   - payload: 扫码得到的原始字符串。
    ///   - symbologyRaw: `AVMetadataObject.ObjectType.rawValue`，用于展示与溯源。
    static func parse(payload: String, symbologyRaw: String = "") -> PaintColorDraft {
        let raw = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        let isOwn = ScanSymbology.isOwnLabel(payload: raw)

        guard !raw.isEmpty else {
            return PaintColorDraft(
                rawPayload: payload, symbologyRaw: symbologyRaw, source: .plain,
                code: "", fieldCount: 0, warnings: ["扫到的内容为空"], isOwnLabel: isOwn
            )
        }

        // 1) JSON
        if let object = decodeJSONObject(from: raw) {
            var draft = fromKeyValues(pairs: flatten(object), raw: raw,
                                      symbologyRaw: symbologyRaw, isOwn: isOwn)
            draft.source = .json
            return draft
        }

        // 2) URL
        if let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
           ["http", "https", "artstock", "paint", "color"].contains(scheme) {
            var pairs: [(String, String)] = []
            var pathSegments: [String] = []
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                for item in components.queryItems ?? [] {
                    if let value = item.value { pairs.append((item.name, value)) }
                }
                pathSegments = components.path.split(separator: "/").map(String.init)
            }

            var draft = fromKeyValues(pairs: pairs, raw: raw,
                                      symbologyRaw: symbologyRaw, isOwn: isOwn)
            draft.source = .url
            if ScanSymbology.isBrandMarketingURL(raw) {
                draft.payloadMayBeShared = true
                draft.warnings.append(
                    "这看起来是品牌的公众号 / 官网二维码 —— 同一个品牌所有颜色印的都是同一张，"
                    + "它认不出颜色。请用「认字」读管子上印的颜色名。"
                )
            }

            // 没有显式 code 参数时，路径末段通常就是色号。
            if draft.code.isEmpty {
                if let last = pathSegments.last, !last.isEmpty {
                    draft.code = PaintColorDraft.normalizeCode(last)
                } else if let host = url.host {
                    draft.code = PaintColorDraft.normalizeCode(host)
                }
            }
            return draft
        }

        // 3) GS1
        if let gs1 = parseGS1(raw) {
            var draft = gs1
            draft.symbologyRaw = symbologyRaw
            draft.isOwnLabel = isOwn
            draft.payloadMayBeShared = true
            return draft
        }

        // 4) 键值文本
        let pairs = splitKeyValuePairs(raw)
        if !pairs.isEmpty {
            var draft = fromKeyValues(pairs: pairs, raw: raw,
                                      symbologyRaw: symbologyRaw, isOwn: isOwn)
            draft.source = .keyValue
            if draft.code.isEmpty {
                draft.code = PaintColorDraft.normalizeCode(raw)
                draft.warnings.append("没找到色号字段，已用整段内容作为编号")
            }
            return draft
        }

        // 5) 零售条码 / 纯文本
        //
        // 一维零售条码默认按"可能被多个颜色共用"处理。这是本工程最重要的一条
        // 现实修正：真实反馈「不同颜色的条形码都是一样的」。赌它唯一，
        // 结果就是扫完第一支之后，同一盒里别的颜色永远进不来。
        let isRetail = ScanSymbology.isRetailBarcode(symbologyRaw)
        let hasDigits = raw.contains(where: \.isNumber)
        let isTwoDimensional = ["org.iso.QRCode", "org.iso.Aztec", "org.iso.DataMatrix",
                                "org.iso.PDF417"].contains(symbologyRaw)
        // 二维吗、又一个数字都没有 → 不可能是 SKU，多半是公众号码或一句宣传语。
        let looksBrandLevel = isTwoDimensional && !hasDigits

        var warnings: [String] = []
        if isRetail || looksBrandLevel {
            warnings.append(
                "同一个品牌 / 同一批颜料的不同颜色，条码常常是共用的 —— "
                + "所以条码不能当颜色身份。用「认字」读包装上的颜色名最准。"
            )
        }

        var draft = PaintColorDraft(
            rawPayload: raw, symbologyRaw: symbologyRaw, source: .plain,
            code: PaintColorDraft.normalizeCode(raw),
            fieldCount: 0, warnings: warnings, isOwnLabel: isOwn
        )
        draft.payloadMayBeShared = isRetail || looksBrandLevel
        return draft
    }
}

// MARK: - 规范化

extension PaintColorDraft {
    /// 色号规范化：去空白、转大写，保证同一个码对应同一条记录。
    static func normalizeCode(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

// MARK: - JSON

private extension PaintScanParser {

    static func decodeJSONObject(from raw: String) -> [String: Any]? {
        guard raw.hasPrefix("{") || raw.hasPrefix("[") else { return nil }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let dictionary = object as? [String: Any] { return dictionary }
        if let array = object as? [[String: Any]], let first = array.first { return first }
        return nil
    }

    /// 把嵌套一层的结果摊平成 key/value（如 `{"paint": {...}}`）。
    static func flatten(_ object: [String: Any], depth: Int = 0) -> [(String, String)] {
        var result: [(String, String)] = []
        for (key, value) in object {
            switch value {
            case let string as String:
                result.append((key, string))
            case let number as NSNumber:
                result.append((key, number.stringValue))
            case let nested as [String: Any] where depth < 2:
                result.append(contentsOf: flatten(nested, depth: depth + 1))
            case let array as [Any]:
                if let first = array.first as? String { result.append((key, first)) }
            default:
                continue
            }
        }
        return result
    }

    /// 把 `code=A;name=B` / `色号：A` / `a=1&b=2` 拆成键值对。
    static func splitKeyValuePairs(_ raw: String) -> [(String, String)] {
        let separators = CharacterSet(charactersIn: "\n\r;；|｜&")
        var pairs: [(String, String)] = []

        for line in raw.components(separatedBy: separators) {
            let token = line.trimmingCharacters(in: .whitespaces)
            guard !token.isEmpty else { continue }

            if let range = token.range(of: "=") {
                let key = String(token[token.startIndex..<range.lowerBound])
                let value = String(token[range.upperBound...])
                if !key.trimmingCharacters(in: .whitespaces).isEmpty { pairs.append((key, value)) }
                continue
            }

            for separator in ["：", ":"] {
                if let range = token.range(of: separator) {
                    let key = String(token[token.startIndex..<range.lowerBound])
                    let value = String(token[range.upperBound...])
                    let trimmedKey = key.trimmingCharacters(in: .whitespaces)
                    // 避免把 "https://x" 这种整串当成键值对。
                    if !trimmedKey.isEmpty, !trimmedKey.contains("/") { pairs.append((key, value)) }
                    break
                }
            }
        }
        return pairs
    }
}

// MARK: - GS1

private extension PaintScanParser {

    static var gs1Separator: Character {
        Character(UnicodeScalar(0x1D)!)
    }

    static let gs1FixedLengths: [String: Int] = [
        "01": 14,   // GTIN-14
        "17": 6,    // 有效期 YYMMDD
        "11": 6,    // 生产日期
        "15": 6
    ]

    /// 判断一段内容是否**值得**按 GS1 解析。
    ///
    /// 这一步很关键：用"包含 01"当判据会把 `ART-0001` 这类普通编号也拖进
    /// GS1 分支。只认三种明确形态。
    static func looksLikeGS1(_ raw: String) -> Bool {
        if raw.contains("("), raw.contains(")") { return true }
        if raw.contains(gs1Separator) { return true }
        if raw.count == 16, raw.allSatisfy(\.isNumber), raw.hasPrefix("01") { return true }
        return false
    }

    /// 极简 GS1 解析：只取 GTIN 与批次，其余忽略。
    static func parseGS1(_ raw: String) -> PaintColorDraft? {
        guard looksLikeGS1(raw) else { return nil }

        var code = ""
        var batch: String?
        var parsedAnyAI = false

        if raw.contains("("), raw.contains(")") {
            // 括号写法：按 "(" 切开，每段形如 "AI)值"。
            // ⚠️ 不能按 ")" 切 —— 那样 AI 与它的值会被切到相邻两段里，
            //    结果 AI 全部落空、整个载荷退化成纯文本。（测试用例覆盖了这条）
            for chunk in raw.components(separatedBy: "(") {
                let token = chunk.trimmingCharacters(in: .whitespaces)
                guard let separatorIndex = token.firstIndex(of: ")") else { continue }
                let ai = String(token[token.startIndex..<separatorIndex])
                let body = String(token[token.index(after: separatorIndex)...])
                guard ai.count >= 2, !body.isEmpty else { continue }
                if applyGS1(ai: String(ai.prefix(2)), body: body, code: &code, batch: &batch) {
                    parsedAnyAI = true
                }
            }
        } else {
            var work = Substring(raw)
            while work.count > 2 {
                let ai = String(work.prefix(2))
                let rest = work.dropFirst(2)
                let length: Int
                if ai == "10" {
                    length = min(20, rest.count)
                } else if let fixed = gs1FixedLengths[ai] {
                    length = fixed
                } else {
                    break
                }
                guard rest.count >= length else { break }
                let body = String(rest.prefix(length))
                work = rest.dropFirst(length)
                if applyGS1(ai: ai, body: body, code: &code, batch: &batch) { parsedAnyAI = true }
                if work.first == gs1Separator { work = work.dropFirst() }
            }
            // 有剩余说明不是完整的 GS1 元素串，放弃，交给后续解析器。
            guard work.isEmpty else { return nil }
        }

        guard parsedAnyAI, !code.isEmpty || batch != nil else { return nil }

        var warnings: [String] = []
        if code.isEmpty {
            code = PaintColorDraft.normalizeCode(raw)
            warnings.append("没识别到 GTIN，已用整段内容作为编号")
        }

        let draft = PaintColorDraft(
            rawPayload: raw, symbologyRaw: "", source: .gs1,
            code: code,
            name: nil, brand: nil, series: nil, hex: nil,
            fieldCount: [batch != nil].filter { $0 }.count,
            warnings: warnings,
            isOwnLabel: false
        )
        return draft
    }

    @discardableResult
    static func applyGS1(ai: String, body: String, code: inout String, batch: inout String?) -> Bool {
        switch ai {
        case "01": code = body; return true
        case "10": batch = body; return true
        default: return false
        }
    }
}

// MARK: - 字段归并

private extension PaintScanParser {

    /// 只保留与颜料颜色相关的字段。上一版这里的别名表有 17 个字段
    /// （数量、单位、阈值、供应商、有效期……），那是库存系统的东西，
    /// 对"扫一支颜料"来说是噪声。
    enum Field: CaseIterable {
        case code, name, brand, series, hex
    }

    static let aliases: [Field: [String]] = [
        .code: ["code", "id", "sku", "sn", "barcode", "gtin", "ean", "upc", "no", "number",
                "itemcode", "productcode", "artno", "articleno",
                "编号", "编码", "货号", "色号", "条码", "商品编号", "产品编号"],
        .name: ["name", "title", "color", "colour", "colorname", "product", "productname",
                "displayname", "item",
                "名称", "品名", "颜色", "颜色名", "颜色名称", "色名", "色彩名", "商品名称"],
        .brand: ["brand", "maker", "manufacturer", "vendor", "mfr",
                 "品牌", "厂商", "厂家"],
        .series: ["series", "line", "grade", "range", "collection", "type",
                  "系列", "等级", "级别", "档次"],
        .hex: ["hex", "colorhex", "colourhex", "rgb", "swatch", "value",
               "色值", "颜色值", "色号值"]
    ]

    static func field(forKey key: String) -> Field? {
        let normalized = normalizeKey(key)
        guard !normalized.isEmpty else { return nil }

        // 1) 精确匹配：先跑完所有字段，保证「颜色值」不会被「颜色」抢先命中
        for field in Field.allCases {
            guard let candidates = aliases[field] else { continue }
            if candidates.contains(normalized) { return field }
        }

        // 2) 宽松匹配：键里包含别名（如 "paintColorName"、"商品颜色名称"）
        //
        // ⚠️ 门槛必须区分中英文，这是实测踩过的坑：
        //    英文短串（"id"、"no"）极易误命中，所以要求 >= 3 个字符；
        //    中文是表意文字，"色名""品牌" 这种两字词本身就够明确，
        //    用 3 字门槛会把「颜色名」这个极常见的键整个漏掉。
        for field in Field.allCases {
            guard let candidates = aliases[field] else { continue }
            for candidate in candidates {
                let minimum = containsCJK(candidate) ? 2 : 3
                guard candidate.count >= minimum, normalized.contains(candidate) else { continue }
                return field
            }
        }
        return nil
    }

    /// 是否含中日韩表意文字。
    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)        // 基本汉字
                || (0x3400...0x4DBF).contains(scalar.value) // 扩展 A
        }
    }

    static func normalizeKey(_ key: String) -> String {
        key.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
    }

    static func fromKeyValues(
        pairs: [(String, String)],
        raw: String,
        symbologyRaw: String,
        isOwn: Bool
    ) -> PaintColorDraft {

        var code = ""
        var name: String?
        var brand: String?
        var series: String?
        var hex: String?
        var recognized = 0
        var warnings: [String] = []

        for (key, value) in pairs {
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            guard let field = field(forKey: key) else { continue }

            switch field {
            case .code:
                code = PaintColorDraft.normalizeCode(cleaned)
            case .name:
                name = cleaned
            case .brand:
                brand = cleaned
            case .series:
                series = cleaned
            case .hex:
                if let parsed = normalizeHex(cleaned) {
                    hex = parsed
                } else {
                    warnings.append("颜色值「\(cleaned)」无法识别")
                }
            }
            recognized += 1
        }

        // 名称字段里如果写的是中文色名，顺手转成色值。
        if hex == nil, let name, let parsed = normalizeHex(name) {
            hex = parsed
        }

        return PaintColorDraft(
            rawPayload: raw, symbologyRaw: symbologyRaw, source: .keyValue,
            code: code, name: name, brand: brand, series: series, hex: hex,
            fieldCount: recognized, warnings: warnings, isOwnLabel: isOwn
        )
    }

    /// 颜色值规范化：支持 `#RGB` / `#RRGGBB` / `RRGGBB` / 常见中文色名。
    static func normalizeHex(_ text: String) -> String? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let hex = cleaned.hasPrefix("#") ? String(cleaned.dropFirst()) : cleaned
        if (hex.count == 3 || hex.count == 6), hex.allSatisfy({ $0.isHexDigit }) {
            // 纯 3/6 位十六进制要额外确认不是"恰好全由 A-F 组成的词"
            // （比如 "FACE" 是色值而 "BEAD" 也可能是），这里按色值处理即可。
            if hex.count == 6 {
                if let value = Int(hex, radix: 16) {
                    return String(format: "#%06X", value)
                }
            } else {
                let expanded = hex.map { "\($0)\($0)" }.joined()
                if let value = Int(expanded, radix: 16) {
                    return String(format: "#%06X", value)
                }
            }
        }

        return namedColor(cleaned)
    }

    /// 常见中文色名 → 色值。
    ///
    /// 颜料包装与用户自制标签里经常只写色名，能自动映射的话可以省掉取色这一步。
    static func namedColor(_ text: String) -> String? {
        let table: [(String, String)] = [
            ("朱红", "#E34234"), ("深红", "#8B1A1A"), ("大红", "#D6303A"), ("红", "#D6303A"),
            ("橙", "#F08030"),
            ("柠檬黄", "#FFF44F"), ("土黄", "#C9A227"), ("黄", "#F2C200"),
            ("草绿", "#7BB661"), ("橄榄绿", "#6B8E23"), ("深绿", "#1F6B3A"), ("绿", "#3E9B4F"),
            ("群青", "#2E5BFF"), ("湖蓝", "#2C9BC4"), ("天蓝", "#6FB7E8"), ("蓝", "#2E5BFF"),
            ("紫罗兰", "#7B4FA8"), ("紫", "#7B4FA8"),
            ("粉", "#E48FB0"), ("赭石", "#8B5A2B"), ("熟褐", "#5C4033"), ("棕", "#8B5A2B"),
            ("象牙黑", "#1C1C1E"), ("黑", "#1C1C1E"),
            ("钛白", "#F7F7F5"), ("锌白", "#FAFAF8"), ("白", "#F5F5F5"),
            ("灰", "#8E8E93")
        ]
        // 从长到短匹配，避免"深红"被"红"抢先。
        for (key, value) in table.sorted(by: { $0.0.count > $1.0.count }) where text.contains(key) {
            return value
        }
        return nil
    }
}
