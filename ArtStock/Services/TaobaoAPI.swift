//
//  TaobaoAPI.swift
//  ArtAssist — 美术生的工具箱
//
//  淘宝接入的**纯数据层**：登录入口、登录判定、账号规则、屏幕文字整理。
//
//  ── 这套东西怎么变成现在这样的（值得留着）─────────────────────
//  最早走的是"写死 mtop 接口名 + 用会话 cookie 签名请求"那条路。
//  它有两个治不好的毛病：
//    1. 接口是逆向来的，淘宝一改就废；而且我**没有账号可验证**，
//       第一次跑基本靠你按真实返回反馈。
//    2. 它需要"浏览器会话 cookie"当身份 —— 而身份一旦从 cookie 里算，
//       就必然会出错：`cookie2` 连**匿名访客**都有，`token` 还会变。
//       于是"登录一个账号却出现账号 1、账号 2"。
//
//  现在：
//    · **登录态由浏览器档案承载**（`WKWebsiteDataStore(forIdentifier:)`，iOS 17+），
//      一个档案就是一个账号 —— 不再需要 cookie 参与身份判断。
//    · **读订单靠截图认字**（见 `TaobaoWebSyncView`），不再猜接口。
//    · 登录成功与否**看页面**（`TaobaoLoginDetector`），不读 cookie。
//
//  所以这个文件里已经没有 Cookie、没有签名、没有接口名了。
//

import Foundation

// MARK: - 入口

/// 网页入口。
enum TaobaoWebEndpoint {
    /// 登录页。登录在 App 内的 WebView 里完成 —— 密码只输在淘宝自己的页面上。
    static let loginPage = "https://login.taobao.com/member/login.jhtml"
    /// 已买到的宝贝（订单列表）。同步页面从这里开始。
    static let orderListPage = "https://buyertrade.taobao.com/trade/itemlist/list_bought_items.htm"
}

// MARK: - 登录判定

/// 看**页面**判断"登录成功了吗"。
///
/// ── 为什么改成看页面 ─────────────────────────────────────────
/// 以前是靠"从 WebView 的 cookie 罐里捞 `unb` / `cookie2`"来判断，
/// 那条路的坑就是上面说的：游客也有 `cookie2`，于是把访客当成了账号。
///
/// 页面自己不会骗人：还停在 `login.taobao.com`、标题写着「登录淘宝」，
/// 就是没登录；已经跳到 `taobao.com` / `tmall.com` 的正常页面，就是登录了。
///
/// 这个判据是纯函数，可以用真实 URL 离线钉住（见 TaobaoTests）。
enum TaobaoLoginDetector {

    /// 主机名里的登录特征。`login.taobao.com`、`passport.taobao.com`、
    /// `login.m.taobao.com` 都要被认出来。
    static let loginHostMarkers = ["login", "passport", "auth."]

    /// 路径里的登录特征。
    static let loginPathMarkers = ["login", "newlogin", "passport", "jump"]

    /// 标题里的登录特征（中文页面最可靠的信号之一）。
    static let loginTitleMarkers = ["登录", "登陆", "sign in", "log in", "扫码"]

    /// 这个主机是不是淘宝系的。
    static func isTaobaoHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return ["taobao.com", "tmall.com"].contains { suffix in
            normalized == suffix || normalized.hasSuffix("." + suffix)
        }
    }

    /// 页面看起来已经是登录后的状态。
    static func looksLoggedIn(url: URL?, title: String?) -> Bool {
        // 标题最直接：登录页/扫码页的标题里一定有「登录」两个字
        if let title {
            let lowered = title.lowercased()
            if loginTitleMarkers.contains(where: { lowered.contains($0.lowercased()) }) {
                return false
            }
        }
        guard let url, let host = url.host?.lowercased() else { return false }
        // 不是淘宝的域名（被跳到别的站点、或错误页）→ 不能算登录成功
        guard isTaobaoHost(host) else { return false }
        if loginHostMarkers.contains(where: { host.contains($0) }) { return false }
        let path = url.path.lowercased()
        if loginPathMarkers.contains(where: { path.contains($0) }) { return false }
        return true
    }
}

// MARK: - 账号

/// 一个淘宝账号。
///
/// ── **一个浏览器档案就是一个账号** ────────────────────────────
/// `storeIdentifier` 是这份档案的标识，账号的 `id` 就是由它算出来的。
/// 这样"账号身份"不再需要从 cookie 里推断 —— 也就不会再出现
/// "同一个人被记成两个账号"：在同一个档案里登录多少次，
/// 都只会更新同一条记录。
///
/// ⚠️ 这个结构体放在这里（而不是 `TaobaoSessionStore.swift`）是为了让
///    `TaobaoAccountBook` 的规则能被离线测试 —— 那个文件依赖 WebKit。
struct TaobaoAccount: Codable, Identifiable, Equatable, Sendable {
    /// 稳定标识 = `profile:<档案 UUID>`。
    var id: String
    /// 用户起的名字（"我的号" / "家人的号"）。
    var label: String
    var savedAt: Date
    /// 这份档案的标识。nil 只可能出现在没有这个字段的老数据上。
    var storeIdentifier: UUID?
    /// **最后一次确认到"这份档案里是登录状态"**的时间。
    ///
    /// nil = 还没确认过。界面会老实说"未登录"，不会假装已登录 ——
    /// 登录态在档案里，不打开页面就无从得知。
    var signedInAt: Date?

    var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名账号" : trimmed
    }

    /// 是否已确认登录（依据是上次确认，不是猜 cookie）。
    var isSignedIn: Bool { signedInAt != nil }

    /// 由档案标识算出账号 id。
    var profileID: String? {
        storeIdentifier.map { TaobaoAccountBook.profileID(for: $0) }
    }
}

/// 账号列表的整理规则（纯函数，离线测过）。
enum TaobaoAccountBook {

    /// 档案标识 → 账号 id。
    static func profileID(for identifier: UUID) -> String {
        "profile:\(identifier.uuidString)"
    }

    /// 自动生成的显示名（"账号 1" / "账号 2"）—— 用户没起过名字。
    static func isAutoLabel(_ label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("账号 ") else { return false }
        let rest = trimmed.dropFirst(3)
        return !rest.isEmpty && rest.allSatisfy(\.isNumber)
    }

    /// 去重：**一个档案只留一条记录**。
    ///
    /// 顺带把老记录的 id 从"从 cookie 算出来的样子"（`unb:…` / `cookie2:…`）
    /// 归一到 `profile:<档案>` —— 那种 id 正是"账号 1 + 账号 2"的来源，
    /// 不该继续留在数据里。
    static func dedupe(_ accounts: [TaobaoAccount]) -> [TaobaoAccount] {
        var groups: [String: [TaobaoAccount]] = [:]
        for account in accounts {
            let key = account.profileID ?? account.id
            groups[key, default: []].append(account)
        }

        let result: [TaobaoAccount] = groups.map { key, candidates in
            var merged = candidates.max { rank($0) < rank($1) } ?? candidates[0]
            // id 统一成"按档案算"的那个
            merged.id = key
            // 名字：优先留用户起过的，别把手工命名冲掉
            if isAutoLabel(merged.label),
               let named = candidates.first(where: { !isAutoLabel($0.label) }) {
                merged.label = named.label
            }
            // 档案标识一定要留住：丢了它这个账号就要重新登录
            merged.storeIdentifier = merged.storeIdentifier
                ?? candidates.compactMap(\.storeIdentifier).first
            merged.savedAt = candidates.map(\.savedAt).max() ?? merged.savedAt
            // 登录确认时间取最近的一次
            merged.signedInAt = candidates.compactMap(\.signedInAt).max()
            return merged
        }
        return result.sorted { $0.savedAt > $1.savedAt }
    }

    /// 排序用：越大越值得保留。
    private static func rank(_ account: TaobaoAccount) -> Int {
        var score = 0
        if account.storeIdentifier != nil { score += 100 }
        if account.signedInAt != nil { score += 50 }
        if !isAutoLabel(account.label) { score += 10 }
        return score
    }
}

// MARK: - 屏幕文字（OCR）

/// 把 OCR 读到的屏幕文字整理成一段能交给订单解析器的东西。
///
/// ── 为什么读订单靠截图认字 ───────────────────────────────────
/// 试过注入脚本 hook 页面的网络请求来偷响应。**那条路是错的**：
/// 全局 hook 会破坏页面自己的交互（用户根本操作不了网页）。
/// 现在的做法用户看得见：**翻到哪一屏，就截那一屏认字**。
/// 认出来的文字给用户看一眼、能改，然后交给已有的"粘贴订单文字"链路
/// （`OrderTextParser` + `IncomingPackageService`）—— 那条路早就测过了。
enum TaobaoScreenText {

    /// 整理 OCR 出来的行。
    ///
    /// 三件事都是针对 OCR 的实际毛病：
    ///   ① 空行、纯符号行丢掉（分隔线会被读成 "|"、"——" 之类）
    ///   ② 相邻重复行去掉（同一行偶尔被识别两次）
    ///   ③ 行内多余空白压成一个空格
    static func clean(_ lines: [String]) -> String {
        var result: [String] = []
        for raw in lines {
            let collapsed = raw
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !collapsed.isEmpty else { continue }
            // 纯符号/纯标点：对订单解析没有任何用，但会把噪音带进解析器
            guard collapsed.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            // 相邻重复
            if result.last == collapsed { continue }
            result.append(collapsed)
        }
        return result.joined(separator: "\n")
    }

    /// 把新认到的一屏接到已有文字后面。
    ///
    /// 用户会来回翻、也可能对同一屏点两次「识别这一屏」。
    /// 不判重的话文字会越攒越长，商品条目也会重复匹配。
    static func append(_ screen: String, to existing: String) -> String {
        let new = screen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty else { return existing }
        let old = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !old.isEmpty else { return new }
        if old.contains(new) { return old }          // 这一屏已经认过了
        if new.contains(old) { return new }          // 新的一屏是已有内容的超集
        return old + "\n" + new
    }

    /// 这一屏到底认到东西了吗。
    ///
    /// 单独拎出来是为了给用户一句**有用的**反馈：认到 0 行时说"没认到字"
    /// （多半是页面还没加载完或太糊），而不是傻等着。
    static func isUseful(_ screen: String) -> Bool {
        screen.split(separator: "\n").count >= 2
    }
}

// MARK: - 屏幕文字：把噪音挤掉

/// 从一整屏 OCR 结果里挑出"跟买了什么有关"的行。
///
/// ── 为什么需要它 ─────────────────────────────────────────────
/// 淘宝订单页一屏里，真正的商品名可能只占三分之一，其余是：
/// 导航、店铺名、状态标签、按钮文字、价格、日期、"猜你喜欢"……
/// 直接交给订单解析器，就会出现"认出一大堆别的东西"。
///
/// ── 这里最强的武器是**你自己的库** ───────────────────────────
/// 你库里已有的耗材名、颜色名、色号，就是一份**专属词典**：
///   · 认出来的行如果和词典里的东西对得上 → 几乎肯定是真商品，
///     而且顺手把 OCR 认错的字**纠回正确写法**（"樱花橡" → "樱花橡皮"）；
///   · 对不上的行也不一律丢掉 —— 可能真是你没录过的新东西，
///     所以只要它"长得像商品名"就留着。
///
/// 这样既压掉噪音，又不会因为"库里没有"就漏掉新买的画材。
enum TaobaoScreenFocus {

    /// 结果。
    struct Result: Equatable, Sendable {
        /// 保留下来的行（已纠错、已去重）。
        var lines: [String] = []
        /// 其中对上了库里已知物品的（用来告诉用户"认出了几样你的东西"）。
        var matchedNames: [String] = []
        /// 被判定成页面框架/杂讯丢掉的行数。
        var droppedLines = 0
    }

    /// 页面框架词。这些在每一屏都会出现，但跟"买了什么"毫无关系。
    ///
    /// 只放**确定的**界面词 —— 宁可漏掉几个杂讯，也不能把商品名误杀
    /// （比如"橡皮"是商品，"评价"不是）。
    static let chromeWords: [String] = [
        "淘宝", "天猫", "我的淘宝", "我的订单", "已买到的宝贝", "购物车", "收藏夹", "收藏",
        "客服", "联系客服", "在线客服", "评价", "查看物流", "确认收货", "退款", "退货",
        "投诉", "申请售后", "售后", "加入购物车", "立即购买", "再买一单", "删除订单",
        "店铺", "进店逛逛", "旺旺", "销量", "已售", "月销", "规格", "颜色分类",
        "合计", "实付款", "实付", "运费", "优惠", "红包", "积分", "满减", "领券",
        "优惠券", "包邮", "免运费", "正品", "保障", "七天无理由", "极速退款",
        "订单号", "订单编号", "订单详情", "查看详情", "更多", "展开", "收起",
        "推荐", "为你推荐", "猜你喜欢", "广告", "活动", "全部", "上一页", "下一页",
        "首页", "尾页", "搜索", "筛选", "综合", "新品", "价格", "登录", "注册",
        "已完成",
        "共", "条", "件", "确定", "取消", "返回", "分享", "举报", "卖家",
        // 「数量 2」是每张订单卡片都有的标签，不是商品
        "数量",
    ]

    /// 状态短语。这些用**包含**匹配，而不是整行相等。
    ///
    /// 为什么可以放宽：它们是无歧义的物流/交易措辞（"已签收""正在派送"），
    /// 商品名里不会出现这种词。而"快递运输中"这种前面带前缀的写法很常见，
    /// 用整行相等就漏了。
    ///
    /// ⚠️ 注意这里放的是**短语**而不是"快递"这个词 ——
    ///    "快递"可能是商品名的一部分（比如"快递包装盒"），误杀代价更大。
    static let statusPhrases: [String] = [
        "运输中", "运送中", "派送中", "正在派送", "已签收", "已发货", "待发货",
        "待揽收", "已揽收", "待收货", "待付款", "待评价", "交易成功", "交易关闭",
        "确认收货", "查看物流", "已到达", "快件已", "物流信息",
    ]

    /// 整理一屏。
    ///
    /// - Parameter knownNames: 用户库里的东西（耗材名、颜色名、色号）。
    ///   传空数组也能用，只是少了"纠错 + 认出你自己的东西"这一层。
    static func focus(_ lines: [String], knownNames: [String]) -> Result {
        var result = Result()
        var seen = Set<String>()
        // 词典先归一化并按长度降序 —— 匹配时长名字优先，
        // 否则"樱花"会先命中"樱花橡皮"的子串。
        let dictionary = knownNames
            .map { ($0, normalize($0)) }
            .filter { !$0.1.isEmpty }
            .sorted { $0.1.count > $1.1.count }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            // 快递单号必须留下 —— 它是"这单到哪了"的唯一凭据
            let hasTracking = looksLikeTrackingNumber(line)

            if !hasTracking, isChrome(line) {
                result.droppedLines += 1
                continue
            }

            // 先看能不能对上库里的东西（对上就用**正确写法**替换）
            if let canonical = bestMatch(for: line, dictionary: dictionary) {
                if seen.insert(canonical).inserted {
                    result.lines.append(canonical)
                    if !result.matchedNames.contains(canonical) {
                        result.matchedNames.append(canonical)
                    }
                }
                continue
            }

            // 对不上：只要像商品名/单号就留着（可能是没录过的新东西）
            if hasTracking || isProductLike(line) {
                if seen.insert(line).inserted { result.lines.append(line) }
            } else {
                result.droppedLines += 1
            }
        }
        return result
    }

    // MARK: 判断

    /// 归一化：去掉空白与常见标点，全角转半角，小写化。
    ///
    /// 目的是让"温莎·牛顿 白"和"温莎牛顿白"能对上 ——
    /// 淘宝标题里的空格、圆点、括号都非常随意。
    static func normalize(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            var value = scalar
            // 全角 ASCII（！-～）→ 半角
            if scalar.value >= 0xFF01, scalar.value <= 0xFF5E {
                value = Unicode.Scalar(scalar.value - 0xFEE0) ?? scalar
            }
            // 全角空格 → 普通空格
            if value.value == 0x3000 { value = " " }
            let character = Character(value)
            if character.isWhitespace { continue }
            if "·・•-—_()（）[]【】{}<>《》,，.。;；:：!！?？'\"\"、/\\|~*#".contains(character) {
                continue
            }
            out.append(Character(String(value).lowercased()))
        }
        return out
    }

    /// 是不是页面框架上的字（不是商品）。
    static func isChrome(_ line: String) -> Bool {
        let normalized = normalize(line)
        guard !normalized.isEmpty else { return true }

        // 太短：单字、两个字的碎片基本是图标标签
        if normalized.count <= 1 { return true }
        // 纯数字 / 价格 / 日期 / 时间：不是商品名
        if normalized.allSatisfy({ $0.isNumber }) { return true }
        if looksLikePriceOrDate(line) { return true }
        // 物流/交易状态（用包含匹配，见 statusPhrases 的说明）
        if statusPhrases.contains(where: { line.contains($0) }) { return true }
        // "共 3 件" "第 2 页" 这类
        if normalized.hasPrefix("共") && normalized.hasSuffix("件") { return true }
        if normalized.hasPrefix("第") && normalized.hasSuffix("页") { return true }
        // 完全是框架词，或者"框架词 + 一两个字符"（如"店铺：XX旗舰店"）
        for word in chromeWords {
            let key = normalize(word)
            guard !key.isEmpty else { continue }
            if normalized == key { return true }
            // 以"某词：/某词|"开头的行是标签，不是商品
            if normalized.hasPrefix(key), normalized.count <= key.count + 2 { return true }
        }
        return false
    }

    /// 价格、日期、时间、页码这一类形状。
    static func looksLikePriceOrDate(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        if text.contains("¥") || text.contains("￥") { return true }
        // 日期：2024-05-01 / 2024/5/1 / 2024年5月1日
        if text.contains("年") && text.contains("月") { return true }
        let digits = text.filter { $0.isNumber }
        let others = text.filter { !$0.isNumber }
        let dateSeparators = others.filter { "-/:.".contains($0) }
        // 全是数字和日期分隔符 → 日期或编号
        if !digits.isEmpty, others.count == dateSeparators.count,
           others.count <= 4, digits.count >= 4 {
            // 但"JT3177669884834"这种字母开头的单号不是这里该管的事
            return true
        }
        // 时间：12:30 / 12:30:05
        if dateSeparators.contains(":"), digits.count >= 3, others.count <= 2 { return true }
        return false
    }

    /// 像不像快递单号。
    ///
    /// 只认形状，不判是哪家快递 —— 判定承运商是 `TrackingNumberParser` 的活，
    /// 而这里只要"别把这个号当成杂讯丢掉"。
    static func looksLikeTrackingNumber(_ line: String) -> Bool {
        let upper = line.uppercased()
        var current = ""
        var candidates: [String] = []
        for character in upper {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else {
                if !current.isEmpty { candidates.append(current) }
                current = ""
            }
        }
        if !current.isEmpty { candidates.append(current) }

        for candidate in candidates {
            let digits = candidate.filter { $0.isNumber }.count
            let letters = candidate.count - digits
            // 顺丰/京东这类：纯数字 12 位以上
            if letters == 0, digits >= 12 { return true }
            // 极兔/中通这类：字母 + 12 位左右数字（JT3177669884834）
            if letters >= 1, letters <= 3, digits >= 9 { return true }
        }
        return false
    }

    /// 像不像一个商品名。
    ///
    /// 判据刻意宽松：库里没有的新画材也要能进来。
    static func isProductLike(_ line: String) -> Bool {
        let normalized = normalize(line)
        guard normalized.count >= 3 else { return false }
        // 至少要有中文或字母 —— 纯符号/纯数字已经被 isChrome 拦掉了
        let hasWord = line.contains { $0.isLetter }
        guard hasWord else { return false }
        // 全是英文且很短的多半是按钮/标签（"BUY"、"OK"）
        let cjkCount = line.filter { $0.unicodeScalars.first.map { (0x4E00...0x9FFF).contains($0.value) } ?? false }.count
        if cjkCount == 0, normalized.count < 6 { return false }
        return true
    }

    // MARK: 与词典比对

    /// 在一行里找出最匹配的已知物品名。找不到返回 nil。
    static func bestMatch(for line: String,
                          dictionary: [(String, String)]) -> String? {
        let normalized = normalize(line)
        guard !normalized.isEmpty else { return nil }

        // ① 整行包含某个已知名字（最常见：标题里带"樱花橡皮"）
        for (canonical, key) in dictionary where normalized.contains(key) {
            return canonical
        }
        // ② 整行是某个已知名字的一截（OCR 只认出一部分）
        for (canonical, key) in dictionary where key.contains(normalized) {
            // 至少认出一半以上才算，避免"白"字命中"温莎牛顿白"
            if Double(normalized.count) >= Double(key.count) * 0.5 { return canonical }
        }
        // ③ 形近字纠错：在行里找**最像词典条目的那个片段**。
        //
        //    ⚠️ 必须按片段比，不能拿整行比：商品标题常常是
        //    "温莎牛顿白 补充装 60ml"，把整行跟"温莎牛顿白"比，
        //    多出来的那截会把相似度稀释到 0.44 —— 于是认错字纠正不了。
        //    这也正是"识别要加强"里最实际的一条。
        var best: (canonical: String, score: Double)?
        for (canonical, key) in dictionary {
            // 便宜的预筛：行里得**含有这个词的大部分字**，否则直接跳过。
            // 不做这层的话，词典几百条 × 每行几十个窗口，会明显卡顿。
            guard characterOverlap(normalized, key) >= 0.6 else { continue }
            let score = bestWindowSimilarity(normalized, key)
            if score >= matchThreshold, score > (best?.score ?? 0) {
                best = (canonical, score)
            }
        }
        return best?.canonical
    }

    /// 判定"是同一个东西"的相似度门槛。
    ///
    /// 0.75 是权衡：再低会把"马利牌素描纸"认成"樱花橡皮"之类别的东西，
    /// 再高则改不动"牛/午"这种只错一个字的形近字。
    static let matchThreshold = 0.75

    /// 行里含有这个词多少比例的字（多重集不做，用集合就够做预筛）。
    static func characterOverlap(_ line: String, _ key: String) -> Double {
        guard !key.isEmpty else { return 0 }
        let lineCharacters = Set(line)
        let hit = key.reduce(0) { $0 + (lineCharacters.contains($1) ? 1 : 0) }
        return Double(hit) / Double(key.count)
    }

    /// 在 `line` 里滑窗，找和 `key` 最像的那一段的相似度。
    ///
    /// 窗口宽度在 key 长度上下浮动 1，容忍 OCR 多认/少认一个字。
    static func bestWindowSimilarity(_ line: String, _ key: String) -> Double {
        let characters = Array(line)
        let keyLength = key.count
        guard !characters.isEmpty, keyLength > 0 else { return 0 }
        // 行比词短：直接整行比
        if characters.count <= keyLength { return similarity(line, key) }

        var best = 0.0
        for width in [keyLength, keyLength + 1, keyLength - 1] where width > 0 {
            guard width <= characters.count else { continue }
            for start in 0...(characters.count - width) {
                let window = String(characters[start..<(start + width)])
                best = max(best, similarity(window, key))
                if best >= 0.999 { return best }   // 已经一模一样，不用再找
            }
        }
        return best
    }

    /// 两串的相似度（0…1）。用最长公共子序列的比值。
    ///
    /// 选它而不是编辑距离：OCR 的错误多是**认错字**（同为 1 个字符的替换），
    /// LCS 对这种"顺序不变、个别字错"的情况判断更稳。
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(lhs), b = Array(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for i in 1...a.count {
            current[0] = 0
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1] + 1
                    : max(previous[j], current[j - 1])
            }
            previous = current
        }
        let lcs = previous[b.count]
        return Double(2 * lcs) / Double(a.count + b.count)
    }
}
