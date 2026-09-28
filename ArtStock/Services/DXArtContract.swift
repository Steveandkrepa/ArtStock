//
//  DXArtContract.swift
//  ArtAssist — 美术生的工具箱
//
//  DXArt 教材接口的**契约层**：地址拼装、请求头、响应解析。
//
//  ── 这个文件存在的理由 ───────────────────────────────────────
//  这部分是从一份能跑通的 Python 脚本（a-Shell 里用的）搬过来的。
//  搬的时候刻意做了两件事：
//
//  1. **把纯逻辑和网络分开。** 这个文件只用 Foundation，
//     不 import URLSession 的调用点、不碰 SwiftData。
//     这样"接口返回的 JSON → 我理解的数据"这一步能在 macOS 上跑回归测试 ——
//     接口一旦改字段，测试会立刻红，而不是等到用户翻页时白屏。
//
//  2. **对脏数据更宽容。** 原脚本有几处会直接抛异常：
//       · `int(page_num)` —— 页码是字符串或 null 就崩
//       · `data["data"]["chapterList"]` —— 少一层就 KeyError
//     这些在真机上就是"点一下卡死/闪退"。这里全部改成有默认值的安全解析，
//     并且每个可疑点都有测试盯着。
//
//  ⚠️ 请求头里的 `version` 与 URL 里的 `appVersion` 是**厂家客户端版本号**，
//     写死在这里。厂家升级 App 后这两个值可能失效 ——
//     所以界面上留了「接口设置」入口可以改，不用等我重新打包。
//

import Foundation

// MARK: - 配置

/// 接口配置。可以在设置里改，改完存 UserDefaults。
struct DXArtConfig: Codable, Equatable, Sendable {

    /// 后端域名。
    var host: String
    /// 请求头 `version`。
    var apiVersion: String
    /// 查询参数 `appVersion`。
    var appVersion: String
    /// `equipmentType`：pad / phone。
    var equipmentType: String
    /// 这两个是厂家客户端里硬编码的，逆向出来的。
    var clientID: String
    var clientSecret: String
    /// 取页时请求的宽度。原脚本用 1230。
    var level3Width: Int
    /// 搜索每页条数（原脚本 50）。接口不接受更大。
    var searchPageSize: Int

    /// 从原 Python 脚本里搬过来的原值 —— 一个都没动。
    ///
    /// 这些不是"我觉得合适"，是**实测能跑通的值**。改动前先想清楚。
    static let standard = DXArtConfig(
        host: "https://api.dxart.tech",
        apiVersion: "1.2.1",
        appVersion: "1.2.1",
        equipmentType: "pad",
        clientID: "yinshi_client",
        clientSecret: "123",
        level3Width: 1230,
        searchPageSize: 50
    )

    // MARK: 持久化

    private static let storageKey = "dxart.config.override"

    /// 读配置：默认值 + 用户在设置里的覆盖。
    static func load() -> DXArtConfig {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode(DXArtConfig.self, from: data) else {
            return .standard
        }
        return saved
    }

    static func save(_ config: DXArtConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func resetToStandard() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    var isCustomized: Bool {
        self != .standard
    }

    /// 去掉末尾斜杠、补上 https://，把用户随手敲的域名收敛成可用形式。
    static func normalizeHost(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return standard.host }
        if !text.lowercased().hasPrefix("http://") && !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

// MARK: - 地址与请求头

/// 接口地址拼装。纯函数，没有副作用 —— 可以直接断言 URL 长什么样。
enum DXArtEndpoint {

    /// 下发短信验证码（GET）。
    static func sms(phone: String, config: DXArtConfig) -> URL? {
        var components = URLComponents(string: config.host + "/api/test/sendMs")
        components?.queryItems = [URLQueryItem(name: "phone", value: phone)]
        return components?.url
    }

    /// 手机号 + 验证码换 token（POST）。
    ///
    /// ⚠️ 参数顺序与原脚本保持一致。这类后端偶尔会有按顺序取参的实现，
    ///    改顺序风险大于收益。
    static func token(phone: String, code: String, config: DXArtConfig) -> URL? {
        var components = URLComponents(string: config.host + "/api/yinshi-oauth-server/oauth/token")
        components?.queryItems = [
            URLQueryItem(name: "grant_type", value: "phoneCode"),
            URLQueryItem(name: "scope", value: "all"),
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "client_secret", value: config.clientSecret),
            URLQueryItem(name: "phone", value: phone),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "appVersion", value: config.appVersion),
            URLQueryItem(name: "equipmentType", value: config.equipmentType)
        ]
        return components?.url
    }

    /// 搜索教材（GET）。
    static func search(keyword: String, page: Int = 1, config: DXArtConfig) -> URL? {
        var components = URLComponents(string: config.host + "/api/test/liegongTopSearch/search")
        components?.queryItems = [
            URLQueryItem(name: "pageNum", value: String(page)),
            URLQueryItem(name: "pageSize", value: String(config.searchPageSize)),
            // type=7 是教材分类，原脚本实测值
            URLQueryItem(name: "type", value: "7"),
            URLQueryItem(name: "values", value: keyword)
        ]
        return components?.url
    }

    /// 取某本书的全部页（POST）。
    static func chapters(textbookID: Int, config: DXArtConfig) -> URL? {
        URL(string: config.host + "/api/yinshi-api-project/textbook/getChapter")
    }

    /// 取页的 POST body。
    static func chapterBody(textbookID: Int, config: DXArtConfig) -> [String: Any] {
        ["level3Width": config.level3Width, "textbookId": textbookID]
    }

    /// 请求头。
    ///
    /// `Host` 故意不设：URLSession 会按 URL 自动填，手写反而可能在重定向时出错。
    /// 原脚本手写 `Host` 是因为它用的 requests 在某些代理下需要。
    static func headers(config: DXArtConfig, token: String? = nil) -> [String: String] {
        var headers: [String: String] = [
            "version": config.apiVersion,
            "Content-Type": "application/json",
            "Accept": "application/json",
            // 伪装成 iPad 上的 App。后端可能按 UA 分流，保持原脚本的值。
            "User-Agent": "Mozilla/5.0 (iPad; CPU OS 18_7 like Mac OS X) "
                + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        ]
        if let token, !token.isEmpty {
            headers["Authorization"] = token
        }
        return headers
    }

    /// 取教材图片用的请求头。
    static func imageHeaders() -> [String: String] {
        [
            "User-Agent": "Mozilla/5.0 (iPad; CPU OS 18_7 like Mac OS X) AppleWebKit/605.1.15",
            "Accept": "image/webp,image/apng,image/*,*/*;q=0.8"
        ]
    }
}

// MARK: - 解析结果

/// 搜索到的一本书。
struct TextbookSummary: Hashable, Sendable, Identifiable {
    var remoteID: Int
    var name: String
    /// 热度。
    var viewCount: Int
    var coverURL: String?

    var id: Int { remoteID }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名教材 \(remoteID)" : trimmed
    }
}

/// 书的一页。
struct TextbookPageInfo: Hashable, Sendable {
    /// 页码（来自 `pagination`）。1 起。
    var pageNumber: Int
    /// 图片地址（已去掉查询串）。
    var remoteURL: String
}

// MARK: - 错误

enum DXArtError: LocalizedError, Equatable {
    case network(String)
    case badResponse(code: Int, message: String)
    /// 401 / 凭证失效。
    case unauthorized(String)
    case empty(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .network(let detail):
            return "网络请求失败：\(detail)"
        case .badResponse(let code, let message):
            return "接口返回错误（\(code)）：\(message)"
        case .unauthorized(let message):
            return "登录已失效，请重新登录。\(message)"
        case .empty(let what):
            return "没有找到\(what)。"
        case .decoding(let detail):
            return "接口返回的内容看不懂，可能是厂家改了接口：\(detail)"
        }
    }

    /// 是不是"需要重新登录"。
    var requiresRelogin: Bool {
        if case .unauthorized = self { return true }
        return false
    }
}

// MARK: - 解析器

/// 把接口返回的 JSON 变成上面那些结构。
///
/// 每个方法都在"缺字段/类型不对"时给出**可读的错误**，而不是崩。
enum DXArtResponseParser {

    // MARK: 通用取值

    /// 从字典里按路径取值，路径上任一层不是字典就返回 nil。
    static func value(in object: Any?, path: [String]) -> Any? {
        var current = object
        for key in path {
            guard let dict = current as? [String: Any] else { return nil }
            current = dict[key]
        }
        return current
    }

    /// 宽松转 Int：支持数字、数字字符串、浮点。
    ///
    /// 原脚本直接 `int(page_num)` —— 页码是 `"12"` 或 `null` 时直接抛异常。
    /// 接口里这两种情况都可能出现。
    static func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let value as Int: return value
        case let value as Double: return Int(value)
        case let value as Bool: return value ? 1 : 0
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let int = Int(trimmed) { return int }
            if let double = Double(trimmed) { return Int(double) }
            return nil
        default: return nil
        }
    }

    /// 宽松转字符串：数字也能变字符串。
    static func stringValue(_ raw: Any?) -> String? {
        switch raw {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let value as Int: return String(value)
        case let value as Double: return String(value)
        default: return nil
        }
    }

    /// 顶层 `code`。
    static func responseCode(_ root: Any?) -> Int? {
        intValue(value(in: root, path: ["code"])) ?? intValue(value(in: root, path: ["status"]))
    }

    /// 顶层 `msg` / `message`。
    static func responseMessage(_ root: Any?) -> String {
        stringValue(value(in: root, path: ["msg"]))
            ?? stringValue(value(in: root, path: ["message"]))
            ?? stringValue(value(in: root, path: ["error"]))
            ?? "未知错误"
    }

    /// 先检查 code，不通过就抛。
    ///
    /// 注意：搜索接口在**没有带凭证**时会返回 401，文案是 Spring Security 的
    /// "Full authentication is required..."。这种要转成"请重新登录"。
    static func requireSuccess(_ root: Any?, what: String) throws {
        let code = responseCode(root)
        guard let code else {
            // 有的接口不返回 code，只返回数据。只有连数据都没有才算错。
            if root is [String: Any] { return }
            throw DXArtError.decoding("返回的不是 JSON 对象（\(what)）")
        }
        guard code == 200 else {
            let message = responseMessage(root)
            if code == 401 || code == 403 {
                throw DXArtError.unauthorized(message)
            }
            throw DXArtError.badResponse(code: code, message: message)
        }
    }

    /// Data → JSON 对象。
    static func jsonObject(from data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<二进制>"
            throw DXArtError.decoding("\(error.localizedDescription)；开头是：\(preview)")
        }
    }

    // MARK: 登录

    /// 下发验证码接口：只要 code == 200 就算成功。
    static func parseSendSMS(_ data: Data) throws {
        let root = try jsonObject(from: data)
        try requireSuccess(root, what: "发送验证码")
    }

    /// token 接口：取 `data.access_token`。
    static func parseToken(_ data: Data) throws -> String {
        let root = try jsonObject(from: data)
        try requireSuccess(root, what: "登录")
        guard let token = stringValue(value(in: root, path: ["data", "access_token"]))
                ?? stringValue(value(in: root, path: ["access_token"])) else {
            throw DXArtError.decoding("登录成功但没找到 access_token")
        }
        return token.lowercased().hasPrefix("bearer") ? token : "Bearer \(token)"
    }

    // MARK: 搜索

    /// 搜索接口的书籍列表。
    ///
    /// 原脚本从顶层 `rows` 取，再读每条的 `liegongTextbook`。
    /// 这里保留这条主路径，另外容忍几种常见包装（`data.rows` / `data.list` /
    /// `records`）—— 厂家改一层包装是很常见的，多试两种比直接报错好，
    /// 但也**不会无限制地猜**：找不到就明确报"没找到教材"。
    static func parseSearch(_ data: Data) throws -> [TextbookSummary] {
        let root = try jsonObject(from: data)
        try requireSuccess(root, what: "搜索")

        let rows = (value(in: root, path: ["rows"]) as? [Any])
            ?? (value(in: root, path: ["data", "rows"]) as? [Any])
            ?? (value(in: root, path: ["data", "list"]) as? [Any])
            ?? (value(in: root, path: ["data", "records"]) as? [Any])
            ?? (value(in: root, path: ["data"]) as? [Any])

        guard let rows else {
            throw DXArtError.decoding("搜索结果里没有书籍列表（rows）")
        }

        var result: [TextbookSummary] = []
        var seen = Set<Int>()

        for row in rows {
            // 有的返回把书的信息直接放在行里，有的再包一层 liegongTextbook
            let node = (value(in: row, path: ["liegongTextbook"]) as? [String: Any])
                ?? (row as? [String: Any])
            guard let node else { continue }

            guard let id = intValue(node["id"]) ?? intValue(node["textbookId"]) else { continue }
            guard !seen.contains(id) else { continue }

            let name = stringValue(node["textbookName"])
                ?? stringValue(node["name"])
                ?? stringValue(node["title"])
                ?? "未命名教材 \(id)"

            let views = intValue(node["textbookViewTotal"])
                ?? intValue(node["viewTotal"])
                ?? intValue(node["views"])
                ?? 0

            let cover = stringValue(node["thumbnailUrl"])
                ?? stringValue(node["textbookCoverPicture"])
                ?? stringValue(node["cover"])

            seen.insert(id)
            result.append(TextbookSummary(
                remoteID: id, name: name, viewCount: views, coverURL: cover
            ))
        }

        return result
    }

    // MARK: 取页

    /// 章节接口的页列表。
    ///
    /// 原脚本：`data.chapterList[].{pagination, textbookChapterFilePath}`，
    /// 图片地址 `split("?")[0]` 去掉查询串。
    ///
    /// 这里额外做了三件事（都是原脚本会出问题的地方）：
    ///   · 页码解析失败的行**跳过**，不是整本书失败
    ///   · 页码去重（同一页返回多次的话，下载会重复劳动）
    ///   · 按页码排序，保证翻页顺序正确
    static func parseChapters(_ data: Data) throws -> [TextbookPageInfo] {
        let root = try jsonObject(from: data)
        try requireSuccess(root, what: "获取教材页")

        let list = (value(in: root, path: ["data", "chapterList"]) as? [Any])
            ?? (value(in: root, path: ["data", "list"]) as? [Any])
            ?? (value(in: root, path: ["chapterList"]) as? [Any])
            ?? (value(in: root, path: ["data"]) as? [Any])

        guard let list else {
            throw DXArtError.decoding("返回里没有 chapterList")
        }

        var byPage: [Int: TextbookPageInfo] = [:]

        for item in list {
            guard let node = item as? [String: Any] else { continue }
            guard let pageNumber = intValue(node["pagination"]) ?? intValue(node["page"]) ?? intValue(node["pageNum"]),
                  pageNumber > 0 else { continue }

            let raw = stringValue(node["textbookChapterFilePath"])
                ?? stringValue(node["filePath"])
                ?? stringValue(node["url"])
            guard let raw, let url = cleanImageURL(raw) else { continue }

            // 同页码后出现的覆盖先出现的（接口通常把更新的一页放后面）
            byPage[pageNumber] = TextbookPageInfo(pageNumber: pageNumber, remoteURL: url)
        }

        let pages = byPage.values.sorted { $0.pageNumber < $1.pageNumber }
        guard !pages.isEmpty else {
            throw DXArtError.empty("可用的教材页面")
        }
        return pages
    }

    /// 图片地址清洗：去掉查询串，并校验是 http(s)。
    ///
    /// 原脚本 `raw_url.split("?")[0]`。保留这个行为 ——
    /// 查询串通常是会过期的签名，带着它反而可能 403；
    /// 而且去掉之后同一张图的 URL 稳定，本地缓存的键也就稳定。
    static func cleanImageURL(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let queryIndex = text.firstIndex(of: "?") {
            text = String(text[text.startIndex..<queryIndex])
        }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return text
    }
}
