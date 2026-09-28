//
//  DXArtClient.swift
//  ArtAssist — 美术生的工具箱
//
//  DXArt 教材接口的调用层：登录、搜索、取页、下楼图。
//
//  ── 和原 Python 脚本的对应关系 ───────────────────────────────
//      auto_login()        → DXArtSession.sendCode / verify
//      search_books()      → DXArtClient.search
//      get_book_pages()    → DXArtClient.chapters
//      download_task()     → TextbookDownloader（在另一个文件里）
//
//  地址拼装与 JSON 解析在 `DXArtContract.swift` 里（纯逻辑、有测试）。
//  这个文件只负责"把请求发出去、把 Data 交给解析器"。
//
//  ── 凭证的存放 ───────────────────────────────────────────────
//  `DXArtSession` 是唯一持有 token 的地方：内存一份 + Keychain 一份。
//  原脚本存明文文件，这里换成 Keychain（见 Keychain.swift 的说明）。
//

import Foundation
import Observation

// MARK: - 网络传输

/// 只负责发请求、拿 Data。不含业务语义。
///
/// 标 `Sendable`：它只有一个 `let` 的 URLSession（本身线程安全），
/// 没有可变状态。下载器要把它交给并发子任务，不标的话跨不过去。
final class DXArtTransport: Sendable {

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        // 原脚本是 timeout=(5, 10)：连接 5 秒、读取 10 秒。
        // 取页接口有时会慢一点，读取放宽到 20 秒。
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func data(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DXArtError.network("没有收到 HTTP 响应")
            }
            // 注意：这个后端在业务失败时也返回 HTTP 200，
            // 真正的错误码在 body 里的 `code`（解析器负责）。
            // 这里的 HTTP 状态码只处理传输层的问题。
            if http.statusCode == 401 || http.statusCode == 403 {
                throw DXArtError.unauthorized("HTTP \(http.statusCode)")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw DXArtError.network("HTTP \(http.statusCode)")
            }
            return data
        } catch let error as DXArtError {
            throw error
        } catch let error as URLError {
            throw DXArtError.network(Self.describe(error))
        } catch {
            throw DXArtError.network(error.localizedDescription)
        }
    }

    /// 把 URLError 翻成人话。原脚本只会打印 `type(e).__name__`（"ConnectionError"），
    /// 那对用户没有任何意义。
    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: return "设备没有联网"
        case .timedOut: return "请求超时，检查一下网络"
        case .cannotFindHost, .cannotConnectToHost: return "连不上服务器，可能域名换了"
        case .networkConnectionLost: return "网络中断"
        case .secureConnectionFailed: return "安全连接失败"
        case .cancelled: return "请求已取消"
        default: return error.localizedDescription
        }
    }
}

// MARK: - 客户端

/// DXArt 接口调用。每个方法对应一个接口，参数与返回都是结构化的。
///
/// 同样标 `Sendable`：无可变状态，多个并发下载任务共用一个实例是安全的。
final class DXArtClient: Sendable {

    private let transport: DXArtTransport

    init(transport: DXArtTransport = DXArtTransport()) {
        self.transport = transport
    }

    // MARK: 登录

    /// 下发短信验证码。
    func sendSMSCode(phone: String, config: DXArtConfig) async throws {
        guard let url = DXArtEndpoint.sms(phone: phone, config: config) else {
            throw DXArtError.network("手机号无法组成请求地址")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in DXArtEndpoint.headers(config: config) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let data = try await transport.data(for: request)
        try DXArtResponseParser.parseSendSMS(data)
    }

    /// 手机号 + 验证码换 token。
    func fetchToken(phone: String, code: String, config: DXArtConfig) async throws -> String {
        guard let url = DXArtEndpoint.token(phone: phone, code: code, config: config) else {
            throw DXArtError.network("无法组成登录地址")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)   // 原脚本也是发一个空 JSON
        for (key, value) in DXArtEndpoint.headers(config: config) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let data = try await transport.data(for: request)
        return try DXArtResponseParser.parseToken(data)
    }

    // MARK: 搜索

    /// 搜索教材。
    func search(keyword: String, page: Int = 1, config: DXArtConfig, token: String?) async throws -> [TextbookSummary] {
        guard let url = DXArtEndpoint.search(keyword: keyword, page: page, config: config) else {
            throw DXArtError.network("无法组成搜索地址")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in DXArtEndpoint.headers(config: config, token: token) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let data = try await transport.data(for: request)
        return try DXArtResponseParser.parseSearch(data)
    }

    // MARK: 取页

    /// 取一本书的全部页地址。
    func chapters(textbookID: Int, config: DXArtConfig, token: String?) async throws -> [TextbookPageInfo] {
        guard let url = DXArtEndpoint.chapters(textbookID: textbookID, config: config) else {
            throw DXArtError.network("无法组成取页地址")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let body = DXArtEndpoint.chapterBody(textbookID: textbookID, config: config)
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        for (key, value) in DXArtEndpoint.headers(config: config, token: token) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let data = try await transport.data(for: request)
        return try DXArtResponseParser.parseChapters(data)
    }

    // MARK: 图片

    /// 教材图片**不需要登录**（CDN 公开地址），所以不带 Authorization。
    ///
    /// 用单独的 session：图片量大，要有自己的超时与缓存策略，
    /// 不能和接口请求共用一个配置。
    private static let imageSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = true
        // 磁盘缓存在 App 自己的沙盒里；但我们还会自己落盘一份到教材目录，
        // 这里只是让同一张图短时间内重复请求时不必再走网络。
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.urlCache = URLCache(
            memoryCapacity: 32 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024
        )
        return URLSession(configuration: configuration)
    }()

    /// 下一张图。返回原始字节 —— 不在这里解码，
    /// 因为下载器只需要"写进文件"，解码交给显示层。
    func imageData(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else {
            throw DXArtError.network("图片地址不合法")
        }
        var request = URLRequest(url: url)
        for (key, value) in DXArtEndpoint.imageHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (data, response) = try await Self.imageSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DXArtError.network("图片没有收到 HTTP 响应")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw DXArtError.network("图片 HTTP \(http.statusCode)")
            }
            guard !data.isEmpty else {
                throw DXArtError.network("图片返回了空内容")
            }
            return data
        } catch let error as DXArtError {
            throw error
        } catch {
            throw DXArtError.network(error.localizedDescription)
        }
    }
}

// MARK: - 会话（凭证）

/// 登录状态与凭证的唯一持有者。
@MainActor
@Observable
final class DXArtSession {

    /// 是否已登录（内存里有 token）。
    private(set) var isLoggedIn = false
    /// 记住的手机号，用于自动填充。
    private(set) var savedPhone: String = ""
    /// 上一次的错误，供界面展示。
    private(set) var lastError: String?

    @ObservationIgnored private var token: String?
    @ObservationIgnored private let client = DXArtClient()

    /// 当前生效的接口配置。
    var config: DXArtConfig = .load() {
        didSet { DXArtConfig.save(config) }
    }

    /// 全局唯一实例。理由同 `TaobaoSessionStore.shared`：
    /// 之前在设置页与教材页各建一个，登录状态互相看不见。
    static let shared = DXArtSession()

    init() {
        restore()
    }

    /// 启动时从 Keychain 恢复登录态。
    ///
    /// 原脚本是读 `dxart_token.txt`。这里换成 Keychain，
    /// 同时把"凭证失效就删掉"这条逻辑保留（见 `handle`）。
    func restore() {
        token = Keychain.read(Keychain.dxartTokenKey)
        isLoggedIn = (token?.isEmpty == false)
        savedPhone = Keychain.read(Keychain.dxartPhoneKey) ?? ""
    }

    // MARK: 登录

    /// 发送验证码。
    func sendCode(phone: String) async throws {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 6 else {
            throw DXArtError.network("手机号看起来不对")
        }
        lastError = nil
        do {
            try await client.sendSMSCode(phone: trimmed, config: config)
            // 发成功了才记住手机号，避免记下打错的号
            Keychain.save(trimmed, for: Keychain.dxartPhoneKey)
            savedPhone = trimmed
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// 用验证码登录。
    func verify(phone: String, code: String) async throws {
        let trimmedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            throw DXArtError.network("验证码不能为空")
        }
        lastError = nil
        do {
            let newToken = try await client.fetchToken(
                phone: trimmedPhone, code: trimmedCode, config: config
            )
            token = newToken
            Keychain.save(newToken, for: Keychain.dxartTokenKey)
            Keychain.save(trimmedPhone, for: Keychain.dxartPhoneKey)
            savedPhone = trimmedPhone
            isLoggedIn = true
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func logout() {
        token = nil
        isLoggedIn = false
        Keychain.clearDXArtCredentials()
    }

    // MARK: 业务调用（统一处理"凭证失效"）

    /// 搜教材。凭证失效时自动登出并把错误抛给界面。
    func search(keyword: String, page: Int = 1) async throws -> [TextbookSummary] {
        let result = try await run { token in
            try await self.client.search(keyword: keyword, page: page, config: self.config, token: token)
        }
        // 搜到了书，但一本都解析不出来 —— 多半是接口改结构了
        if result.isEmpty {
            lastError = nil
        }
        return result
    }

    /// 取某本书的页。
    func chapters(textbookID: Int) async throws -> [TextbookPageInfo] {
        try await run { token in
            try await self.client.chapters(textbookID: textbookID, config: self.config, token: token)
        }
    }

    /// 下楼图（不需要凭证）。
    func imageData(from urlString: String) async throws -> Data {
        try await client.imageData(from: urlString)
    }

    /// 统一的调用包装：把"需要重新登录"这件事在一处处理掉。
    ///
    /// 原脚本的做法是"搜索失败就删掉 token 文件"，比较粗暴 ——
    /// 网络抖动导致的失败也会把凭证删掉，用户得重新收一次短信。
    /// 这里只在**确定是凭证问题**（401/403）时才登出。
    private func run<T>(_ work: @escaping (String?) async throws -> T) async throws -> T {
        do {
            return try await work(token)
        } catch let error as DXArtError {
            if error.requiresRelogin, isLoggedIn {
                logout()
            }
            lastError = error.localizedDescription
            throw error
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }
}
