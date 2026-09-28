//
//  TaobaoSessionStore.swift
//  ArtAssist — 美术生的工具箱
//
//  淘宝账号管理。
//
//  ── 核心一句：**一个浏览器档案就是一个账号** ─────────────────
//  iOS 17 起 `WKWebsiteDataStore(forIdentifier:)` 能给一份**完全独立**的
//  浏览器档案（cookie、localStorage、缓存全隔离）。所以：
//    · 登录 = 在某一份档案里登录；
//    · 切换账号 = 换一份档案来用（什么都不用搬）；
//    · 加账号 = 新开一份空档案（天生干净，不需要清任何东西）；
//    · 两个账号可以**同时**保持登录。
//
//  这里**不再存 cookie、不再读 cookie**。之前那套"从 cookie 里算账号身份"
//  是"登录一个账号却出现账号 1、账号 2"的根源：`cookie2` 连匿名访客都有。
//
//  ── 登录状态怎么知道 ─────────────────────────────────────────
//  档案里的登录态不打开页面是看不到的。所以这里只记一件事：
//  **最后一次确认到登录是什么时候**（`TaobaoAccount.signedInAt`）。
//  没确认过就老实显示"未登录"，不假装。
//

import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class TaobaoSessionStore {

    /// 保存下来的账号。**一个档案一条。**
    private(set) var accounts: [TaobaoAccount] = []
    private(set) var activeAccountID: String?
    /// 正在登录的新账号的档案（账号记录还没建，先挂在这儿）。
    private(set) var pendingStoreIdentifier: UUID?
    private(set) var lastError: String?

    private static let accountsKey = "taobao.accounts"
    private static let activeIDKey = "taobao.activeAccountID"
    /// 用户是否**主动**退出过登录。见 `load()`。
    private static let signedOutKey = "taobao.signedOutOnPurpose"
    /// 账号模型版本。1 = 旧模型（身份从 cookie 算），2 = 档案模型。
    private static let modelVersionKey = "taobao.accountModelVersion"
    private static let currentModelVersion = 2

    /// 全局唯一实例。
    ///
    /// ⚠️ 必须是单例。曾经设置页和库存页各建了一个实例，两边各持一份
    ///    内存里的账号列表、又各自把整份列表写回 Keychain ——
    ///    于是互相覆盖（丢失更新）：改完账号名存不住、列表被覆盖成空
    ///    导致"同步按钮莫名其妙消失"。
    static let shared = TaobaoSessionStore()

    init() {
        load()
    }

    // MARK: - 状态

    var activeAccount: TaobaoAccount? {
        accounts.first { $0.id == activeAccountID }
    }

    /// 当前账号是否**已确认**登录。
    ///
    /// 依据是上次确认，不是猜 cookie —— 所以退出登录时一定要把它清掉。
    var isLoggedIn: Bool { activeAccount?.isSignedIn == true }

    // MARK: - 读写

    /// 从 Keychain 恢复账号列表与当前账号。
    func load() {
        if let text = Keychain.read(Self.accountsKey),
           let data = text.data(using: .utf8),
           let list = try? JSONDecoder().decode([TaobaoAccount].self, from: data) {
            accounts = TaobaoAccountBook.dedupe(list)
        }
        migrateFromCookieModelIfNeeded()

        activeAccountID = UserDefaults.standard.string(forKey: Self.activeIDKey)

        // 当前账号丢了（被删、或键对不上）但有别的账号 → 退回**最近用的**那个。
        // 不这么做的话，用户会莫名其妙变成"未登录"，界面上连入口都没有。
        //
        // ⚠️ 但用户主动点过"退出登录"时不能这样退回 —— 否则退出登录重启后
        //    又自己登回去了。所以留一个显式标记。
        let signedOutOnPurpose = UserDefaults.standard.bool(forKey: Self.signedOutKey)
        if !signedOutOnPurpose,
           activeAccount == nil,
           let latest = accounts.max(by: { $0.savedAt < $1.savedAt }) {
            activeAccountID = latest.id
            UserDefaults.standard.set(latest.id, forKey: Self.activeIDKey)
        }
        if activeAccount == nil { activeAccountID = nil }
        syncActiveSignedInState()
    }

    /// 旧模型（身份从 cookie 算）→ 档案模型的迁移。
    ///
    /// 那个 bug 会留下多条记录，而且**哪一份档案真的登录着已经无从判断**
    /// （新模型不读 cookie 了）。所以这里只留一条（当前激活的，或最近用的），
    /// 标记为"登录状态未确认"，其余清掉 —— 用户重新登录一次即可，
    /// 之后不会再出现重复。标签保留。
    private func migrateFromCookieModelIfNeeded() {
        let version = UserDefaults.standard.integer(forKey: Self.modelVersionKey)
        guard version < Self.currentModelVersion else { return }
        UserDefaults.standard.set(Self.currentModelVersion, forKey: Self.modelVersionKey)

        guard !accounts.isEmpty else { return }
        let active = UserDefaults.standard.string(forKey: Self.activeIDKey)
        let keep = accounts.first { $0.id == active }
            ?? accounts.max(by: { $0.savedAt < $1.savedAt })
        guard let keep else { return }
        var record = keep
        // 老记录的 id 是从 cookie 算的；有档案标识就归一成档案 id
        if let identifier = record.storeIdentifier {
            record.id = TaobaoAccountBook.profileID(for: identifier)
        }
        // 不读 cookie 了，所以"是否登录"无从确认 —— 老实置空，
        // 让界面说"未登录"，而不是显示一个可能已经失效的"已登录"。
        record.signedInAt = nil
        accounts = [record]
        persistAccounts()
        UserDefaults.standard.set(record.id, forKey: Self.activeIDKey)
    }

    private func persistAccounts() {
        guard let data = try? JSONEncoder().encode(accounts),
              let text = String(data: data, encoding: .utf8) else { return }
        Keychain.save(text, for: Self.accountsKey)
    }

    /// 从磁盘重新读一遍账号列表（跨进程时更稳；写之前先对齐免得上覆盖）。
    func reloadAccountsFromDisk() {
        guard let text = Keychain.read(Self.accountsKey),
              let data = text.data(using: .utf8),
              let list = try? JSONDecoder().decode([TaobaoAccount].self, from: data) else { return }
        accounts = TaobaoAccountBook.dedupe(list)
    }

    // MARK: - 档案

    /// 账号的浏览器档案标识。没有就补发一个并持久化。
    ///
    /// 为什么必须持久化：**档案标识丢了就等于档案丢了** —— 那个账号要重新登录。
    func storeIdentifier(for accountID: String) -> UUID {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else {
            return UUID()
        }
        if let existing = accounts[index].storeIdentifier { return existing }
        let fresh = UUID()
        accounts[index].storeIdentifier = fresh
        persistAccounts()
        return fresh
    }

    /// 某个账号的 WebView 数据存储（浏览器档案）。
    func webDataStore(for accountID: String) -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: storeIdentifier(for: accountID))
    }

    /// 登录该用哪份档案：优先新账号的（pending），否则当前账号的。
    func loginStoreIdentifier() -> UUID {
        if let pending = pendingStoreIdentifier { return pending }
        if let active = activeAccountID { return storeIdentifier(for: active) }
        let fresh = UUID()
        pendingStoreIdentifier = fresh
        return fresh
    }

    func loginDataStore() -> WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: loginStoreIdentifier())
    }

    // MARK: - 账号生命周期

    /// 确认"这份档案里登录成功了"，并把它登记成账号。
    ///
    /// 同一个档案登录多少次都只更新同一条记录 —— 这是"不会再出现
    /// 账号 1、账号 2"的根本保证。
    @discardableResult
    func registerLogin(identifier: UUID, label: String? = nil) -> String {
        let id = TaobaoAccountBook.profileID(for: identifier)
        if let index = accounts.firstIndex(where: { $0.id == id }) {
            accounts[index].signedInAt = .now
            accounts[index].savedAt = .now
            if let label, !label.trimmed.isEmpty { accounts[index].label = label.trimmed }
        } else {
            accounts.append(TaobaoAccount(
                id: id,
                label: label?.trimmed.isEmpty == false
                    ? label!.trimmed
                    : "账号 \(accounts.count + 1)",
                savedAt: .now,
                storeIdentifier: identifier,
                signedInAt: .now
            ))
        }
        accounts = TaobaoAccountBook.dedupe(accounts)
        activeAccountID = id
        pendingStoreIdentifier = nil
        persistAccounts()
        UserDefaults.standard.set(id, forKey: Self.activeIDKey)
        // 有账号可用了，撤掉"主动退出"的标记
        UserDefaults.standard.set(false, forKey: Self.signedOutKey)
        lastError = nil
        return id
    }

    /// 开始"添加另一个账号"：**开一份全新的空档案**。
    ///
    /// 不需要清任何东西 —— 新档案天生是空的，所以不会带着上一个账号的
    /// 登录态（那正是旧做法里最容易出错的地方）。
    func beginAddingAccount() {
        pendingStoreIdentifier = UUID()
        activeAccountID = nil
        UserDefaults.standard.removeObject(forKey: Self.activeIDKey)
        UserDefaults.standard.set(true, forKey: Self.signedOutKey)
    }

    /// 切到另一个账号：**只换档案**，不搬任何东西。
    ///
    /// 同步函数，没有 I/O —— 因为登录态本来就在目标账号自己的档案里。
    @discardableResult
    func switchTo(accountID: String) -> Bool {
        guard accounts.contains(where: { $0.id == accountID }) else { return false }
        activeAccountID = accountID
        pendingStoreIdentifier = nil
        UserDefaults.standard.set(accountID, forKey: Self.activeIDKey)
        UserDefaults.standard.set(false, forKey: Self.signedOutKey)
        lastError = nil
        return true
    }

    /// 给账号改个名字（"我的号" / "家人的号"）。
    func rename(accountID: String, to label: String) {
        // 先跟磁盘对齐，避免把别处刚改的东西冲掉
        reloadAccountsFromDisk()
        let trimmed = label.trimmed
        guard !trimmed.isEmpty,
              let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].label = trimmed
        persistAccounts()
    }

    /// 网页里发现登录已失效（比如同步时被弹回登录页）。
    func markSignedOut() {
        guard let index = accounts.firstIndex(where: { $0.id == activeAccountID }) else { return }
        accounts[index].signedInAt = nil
        persistAccounts()
    }

    /// 退出登录：清掉**这份档案**的数据，账号记录与名字保留。
    ///
    /// ⚠️ 记录必须保留。旧版这里会把账号从列表里删掉，于是想加第二个账号
    ///    只能先"退出登录"，一退第一个就没了 —— 永远攒不出两个账号可切。
    ///    退出登录是退出会话，不是删除账号；真要删，列表里每条都有删除按钮。
    func logout() async {
        if let account = activeAccount, let identifier = account.storeIdentifier {
            await clearWebSession(identifier: identifier)
        }
        if let index = accounts.firstIndex(where: { $0.id == activeAccountID }) {
            accounts[index].signedInAt = nil
            persistAccounts()
        }
        activeAccountID = nil
        pendingStoreIdentifier = nil
        UserDefaults.standard.removeObject(forKey: Self.activeIDKey)
        UserDefaults.standard.set(true, forKey: Self.signedOutKey)
        lastError = nil
    }

    /// 删掉一个账号：清掉它的档案数据，再删记录。
    ///
    /// ⚠️ 本想直接删掉整份档案（`removeDataStoreForIdentifier:`），但那个
    ///    类方法在当前 SDK 里**头文件有、二进制里没有**（`WebKit.tbd` 查不到
    ///    这个符号），Swift 侧根本调不到。所以退一步：把档案里的数据全清掉。
    ///    档案目录会留一个空壳，但里面没有任何会话，也不会再被用到。
    func removeAccount(id: String) async {
        if let identifier = accounts.first(where: { $0.id == id })?.storeIdentifier {
            await clearWebSession(identifier: identifier)
        }
        accounts.removeAll { $0.id == id }
        if activeAccountID == id {
            activeAccountID = nil
            UserDefaults.standard.removeObject(forKey: Self.activeIDKey)
            UserDefaults.standard.set(true, forKey: Self.signedOutKey)
        }
        persistAccounts()
    }

    /// 把某份档案里的网页数据全部清掉（退出登录 / 删账号用）。
    ///
    /// ⚠️ 这一步不能省。旧版 `logout()` 只清了内存与 Keychain、没碰 WebKit，
    ///    于是"退出登录 → 再点登录"时 WebView 还带着原会话，
    ///    页面直接跳到登录后状态、被判定成登录成功，**根本走不到输密码**。
    func clearWebSession(identifier: UUID) async {
        let store = WKWebsiteDataStore(forIdentifier: identifier)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
        // removeData 一般已经把 cookie 清掉，但 WebKit 偶尔有残留，
        // 所以再逐条显式删一次 —— 登不干净正是当年那个 bug 的本质。
        let cookieStore = store.httpCookieStore
        let remaining: [HTTPCookie] = await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        for cookie in remaining {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // 新版 SDK 把它改名成 delete(_:completionHandler:)
                cookieStore.delete(cookie) { continuation.resume() }
            }
        }
    }

    /// 当前账号是否登录着 —— 供界面判断时用（不做任何 I/O）。
    private func syncActiveSignedInState() {
        // 目前登录态就是"上次确认过"，不需要额外动作。
        // 留这个方法是为了以后要在启动时校验时有个明确的位置。
    }
}
