//
//  TaobaoTests/main.swift
//  ArtAssist — 美术生的工具箱
//
//  淘宝接入的纯逻辑测试。
//
//  ── 这一套为什么变短了 ───────────────────────────────────────
//  以前这里测的是：mtop 请求签名（md5）、请求体拼装、会话 cookie 判定、
//  三条抓取策略、HTML 内嵌 JSON、订单 JSON 解析、Cookie 罐。
//  那些代码**全删了** —— 因为走的是"App 自己调淘宝接口"这条路，
//  它不可靠（接口是逆向的），而且"账号身份从 cookie 算"直接导致了
//  "登录一个账号却出现账号 1、账号 2"这个 bug。
//
//  现在读订单靠**截图认字**，登录态靠**独立浏览器档案**，登录成功与否
//  **看页面**。所以这里测的就是这三件事里"能被离线验证"的部分：
//    · 屏幕文字整理（OCR 结果的清理与累加）
//    · 登录判定（真实 URL / 标题 → 登录了没）
//    · 账号规则（一个档案一个账号、去重、名字不被冲掉）
//

import Foundation

// MARK: - 迷你测试框架

var passed = 0
var failed = 0

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        passed += 1
        print("  ✅ \(label)")
    } else {
        failed += 1
        let extra = detail()
        print("  ❌ \(label)" + (extra.isEmpty ? "" : "  → \(extra)"))
    }
}

func eq<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    if actual == expected {
        passed += 1
        print("  ✅ \(label)")
    } else {
        failed += 1
        print("  ❌ \(label)  → 实际 \(actual) 期望 \(expected)")
    }
}

// ═══ 1. 屏幕文字整理（OCR 结果的清理）═══
// 这一层是 `TaobaoWebSyncView` 唯一会出错的地方：
// 用户翻到某一屏 → 截图 → OCR 出一堆行 → 整理成能解析的文字。
print("\n═══ 1. 屏幕文字整理 ═══")
do {
    // ① 空行、纯符号行：Vision 会把分隔线、图标读成 "|"、"——" 之类
    let cleaned = TaobaoScreenText.clean([
        "订单号 1234567890", "", "   ", "——", "|", "樱花橡皮 x2"
    ])
    eq("空行与纯符号行被丢掉", cleaned, "订单号 1234567890\n樱花橡皮 x2")
}
do {
    eq("相邻重复行去掉",
       TaobaoScreenText.clean(["温莎牛顿", "温莎牛顿", "樱花橡皮", "樱花橡皮", "樱花橡皮"]),
       "温莎牛顿\n樱花橡皮")
    // 不相邻的重复要保留 —— 一个订单里买了两支同样的笔是正常的
    eq("隔开的重复不算重复",
       TaobaoScreenText.clean(["樱花橡皮", "温莎牛顿", "樱花橡皮"]),
       "樱花橡皮\n温莎牛顿\n樱花橡皮")
}
do {
    eq("多余空白压成一个空格",
       TaobaoScreenText.clean(["  温莎  牛顿   白  "]), "温莎 牛顿 白")
    eq("不换行空格也当空格",
       TaobaoScreenText.clean(["温莎\u{00A0}牛顿"]), "温莎 牛顿")
    eq("全是噪音就是空字符串", TaobaoScreenText.clean(["", "  ", "||"]), "")
}
do {
    eq("第一屏直接就是结果", TaobaoScreenText.append("第一屏", to: ""), "第一屏")
    eq("空白屏不追加", TaobaoScreenText.append("   ", to: "已有"), "已有")
    eq("新的一屏接在后面",
       TaobaoScreenText.append("第二屏", to: "第一屏"), "第一屏\n第二屏")
    // ⚠️ 这条最重要：同一屏认两次不能越攒越多（商品会被重复匹配）
    eq("同一屏重复认不累加", TaobaoScreenText.append("第一屏", to: "第一屏"), "第一屏")
    eq("整屏被包含时也不累加",
       TaobaoScreenText.append("第一屏", to: "第一屏\n第二屏"), "第一屏\n第二屏")
    eq("新屏是旧内容的超集时用新的",
       TaobaoScreenText.append("第一屏\n第二屏", to: "第一屏"), "第一屏\n第二屏")
}
do {
    check("只有一行不算认到（多半是页眉）", !TaobaoScreenText.isUseful("淘宝网"))
    check("两行以上算认到", TaobaoScreenText.isUseful("订单号 123\n樱花橡皮"))
    check("空的不算", !TaobaoScreenText.isUseful(""))
}

// ═══ 2. 登录判定（看页面，不读 cookie）═══
// 这组守的是一个真实 bug：以前靠"cookie 罐里有没有 unb/cookie2"判断登录，
// 而 cookie2 连**匿名访客**都有 —— 于是把没登录的访客页判成了登录成功，
// 顺手把访客存成了"账号 1"。现在改成看页面。
print("\n═══ 2. 登录判定 ═══")
do {
    let url = { URL(string: $0)! }

    // 登录页/扫码页：必须判成"没登录"
    check("登录页 URL → 未登录",
          !TaobaoLoginDetector.looksLoggedIn(
              url: url("https://login.taobao.com/member/login.jhtml"), title: nil))
    check("标题写着登录 → 未登录（哪怕 URL 看着正常）",
          !TaobaoLoginDetector.looksLoggedIn(
              url: url("https://www.taobao.com/"), title: "登录淘宝"))
    check("passport 域 → 未登录",
          !TaobaoLoginDetector.looksLoggedIn(
              url: url("https://passport.taobao.com/x"), title: nil))
    check("手机登录页 → 未登录",
          !TaobaoLoginDetector.looksLoggedIn(
              url: url("https://login.m.taobao.com/msg_login.htm"), title: nil))
    check("扫码登录标题 → 未登录",
          !TaobaoLoginDetector.looksLoggedIn(
              url: url("https://www.taobao.com/"), title: "扫码登录"))
    check("登录跳转路径 → 未登录",
          !TaobaoLoginDetector.looksLoggedIn(
              url: url("https://www.taobao.com/member/login.jump"), title: nil))

    // 登录后的正常页面：必须判成"已登录"
    check("订单列表页 → 已登录",
          TaobaoLoginDetector.looksLoggedIn(
              url: url("https://buyertrade.taobao.com/trade/itemlist/list_bought_items.htm"),
              title: "已买到的宝贝"))
    check("淘宝首页 → 已登录",
          TaobaoLoginDetector.looksLoggedIn(url: url("https://www.taobao.com/"), title: "淘宝网"))
    check("天猫订单页 → 已登录",
          TaobaoLoginDetector.looksLoggedIn(
              url: url("https://buyertrade.tmall.com/trade/itemlist/list_bought_items.htm"),
              title: "已买到的宝贝"))
    check("没标题但 URL 正常 → 已登录",
          TaobaoLoginDetector.looksLoggedIn(
              url: url("https://i.taobao.com/my_taobao.htm"), title: nil))

    // 边界：不能把"非淘宝域名"和"空"当成登录成功
    check("别的域名 → 不算登录成功",
          !TaobaoLoginDetector.looksLoggedIn(url: url("https://example.com/"), title: nil))
    check("没有 URL → 不算登录成功",
          !TaobaoLoginDetector.looksLoggedIn(url: nil, title: "淘宝网"))
    check("淘淘宝.com 这种后缀不算（要按域名分隔点判断）",
          !TaobaoLoginDetector.looksLoggedIn(url: url("https://nottaobao.com/"), title: nil))
}
do {
    check("taobao.com 是淘宝域名", TaobaoLoginDetector.isTaobaoHost("taobao.com"))
    check("子域也算", TaobaoLoginDetector.isTaobaoHost("buyertrade.taobao.com"))
    check("tmall 也算", TaobaoLoginDetector.isTaobaoHost("tmall.com"))
    check("taobao.com.evil.com 不算",
          !TaobaoLoginDetector.isTaobaoHost("taobao.com.evil.com"))
    check("nottaobao.com 不算", !TaobaoLoginDetector.isTaobaoHost("nottaobao.com"))
    check("空的域名不算", !TaobaoLoginDetector.isTaobaoHost(""))
}

// ═══ 3. 账号规则（一个档案 = 一个账号）═══
// 这组守的是用户报的那个 bug：**登录一个账号却同时出现"账号 1""账号 2"**。
// 根因是账号身份从 cookie 里算（游客也有 cookie2），
// 而且临时记录升级成正式身份那一步漏了 cookie2 这一种。
// 现在身份 = 档案标识，同一个档案登录多少次都只更新一条记录。
print("\n═══ 3. 账号规则 ═══")
do {
    eq("档案标识 → 账号 id",
       TaobaoAccountBook.profileID(for: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!),
       "profile:11111111-2222-3333-4444-555555555555")

    check("「账号 1」是自动名", TaobaoAccountBook.isAutoLabel("账号 1"))
    check("「账号 12」也是", TaobaoAccountBook.isAutoLabel("账号 12"))
    check("「我的号」不是", !TaobaoAccountBook.isAutoLabel("我的号"))
    check("「账号本」不是（后面不是数字）", !TaobaoAccountBook.isAutoLabel("账号本"))
    check("「账号 」不是", !TaobaoAccountBook.isAutoLabel("账号 "))
}
do {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let profileA = UUID()
    let profileB = UUID()
    func account(_ identifier: UUID?, _ label: String, _ offset: TimeInterval = 0,
                 signedIn: Bool = false, id: String? = nil) -> TaobaoAccount {
        TaobaoAccount(
            id: id ?? (identifier.map { TaobaoAccountBook.profileID(for: $0) } ?? "unb:9"),
            label: label,
            savedAt: base.addingTimeInterval(offset),
            storeIdentifier: identifier,
            signedInAt: signedIn ? base.addingTimeInterval(offset) : nil
        )
    }

    // ① 同一个档案出现两条 → 合成一条（这就是"账号 1 + 账号 2"的治疗）
    let same = TaobaoAccountBook.dedupe([
        account(profileA, "账号 1"),
        account(profileA, "账号 1", 60, signedIn: true)
    ])
    eq("同一个档案只留一条", same.count, 1)
    eq("id 是档案算出来的那个", same[0].id, TaobaoAccountBook.profileID(for: profileA))
    eq("登录确认时间取最近一次", same[0].signedInAt, base.addingTimeInterval(60))
    eq("保存时间取更晚的", same[0].savedAt, base.addingTimeInterval(60))

    // ② 两个不同档案 → 两条（这才是真的两个账号）
    let two = TaobaoAccountBook.dedupe([
        account(profileA, "我的号"),
        account(profileB, "家人的号", 60)
    ])
    eq("不同档案是不同账号", two.count, 2)

    // ③ 老记录的 id 是从 cookie 算的 → 归一成档案 id
    let legacy = TaobaoAccountBook.dedupe([
        account(profileA, "我的号", id: "unb:2200123456"),
        account(profileA, "我的号", 60, id: "cookie2:abc")
    ])
    eq("老 id 归一成档案 id（同一个档案合成一条）", legacy.count, 1)
    eq("id 换成按档案算的", legacy[0].id, TaobaoAccountBook.profileID(for: profileA))

    // ④ 名字：不能把用户起过的名字冲掉
    let named = TaobaoAccountBook.dedupe([
        account(profileA, "账号 1"),
        account(profileA, "家人的号", 60)
    ])
    eq("保留用户起的名字", named[0].label, "家人的号")

    // ⑤ 档案标识一定要留住（丢了它这个账号就要重新登录）
    let keepStore = TaobaoAccountBook.dedupe([
        account(profileA, "我的号", signedIn: true),
        account(profileA, "我的号", 60, signedIn: true)
    ])
    eq("档案标识保住了", keepStore[0].storeIdentifier, profileA)

    // ⑤b 没有档案标识的**老记录**无法与档案记录合并 —— 这是对的，不是缺陷：
    //     已经不读 cookie 了，"unb:9" 和这份档案是不是同一个人无从判断。
    //     硬合并反而可能把两个真账号并成一个。
    //     这种老数据由 `TaobaoSessionStore.load()` 里的迁移收敛成一条。
    let legacyKept = TaobaoAccountBook.dedupe([
        account(profileA, "我的号"),
        account(nil, "我的号", 60, id: "unb:9")
    ])
    eq("认不出同人的老记录各自保留（交给迁移处理）", legacyKept.count, 2)
    check("但档案标识没被弄丢", legacyKept.contains { $0.storeIdentifier == profileA })

    // ⑥ 排序：最近的在前（界面按这个顺序显示）
    let sorted = TaobaoAccountBook.dedupe([
        account(profileA, "旧的", 0),
        account(profileB, "新的", 600)
    ])
    eq("最近用的排在前面", sorted.first?.label, "新的")

    check("空列表还是空", TaobaoAccountBook.dedupe([]).isEmpty)
}
do {
    // 登录状态：只认"上次确认过"，没确认过就是未登录（不假装）
    let profile = UUID()
    let fresh = TaobaoAccount(
        id: TaobaoAccountBook.profileID(for: profile),
        label: "账号 1", savedAt: .now,
        storeIdentifier: profile, signedInAt: nil
    )
    check("没确认过登录 → isSignedIn 为 false", !fresh.isSignedIn)

    var signedIn = fresh
    signedIn.signedInAt = .now
    check("确认过登录 → isSignedIn 为 true", signedIn.isSignedIn)

    check("displayName 空标签有兜底",
          TaobaoAccount(id: "x", label: "   ", savedAt: .now,
                        storeIdentifier: nil, signedInAt: nil)
            .displayName == "未命名账号")
    eq("profileID 由档案算出来", fresh.profileID,
       TaobaoAccountBook.profileID(for: profile))
    eq("没有档案标识时 profileID 为 nil",
       TaobaoAccount(id: "unb:9", label: "x", savedAt: .now,
                     storeIdentifier: nil, signedInAt: nil).profileID, nil)
}

// ═══ 4. 把噪音挤掉 + 用你自己的库当词典 ═══
// 用户反馈："识别出一大堆别的东西"。这一层就是干这个的。
// 关键平衡：**宁可漏掉几个杂讯，也不能把真商品名误杀** ——
// 所以这组里"不该丢的"用例比"该丢的"还多。
print("\n═══ 4. 屏幕文字聚焦（挤噪音 + 词典纠错）═══")
do {
    // 归一化：淘宝标题里的空格/圆点/括号非常随意
    eq("去掉空格与圆点", TaobaoScreenFocus.normalize("温莎·牛顿 白"), "温莎牛顿白")
    eq("全角字母数字转半角", TaobaoScreenFocus.normalize("ＪＴ１２３"), "jt123")
    eq("去括号", TaobaoScreenFocus.normalize("樱花（橡皮）"), "樱花橡皮")
    eq("小写化", TaobaoScreenFocus.normalize("TALENS"), "talens")
}
do {
    // 快递单号必须留下 —— 它是"这单到哪了"的唯一凭据
    check("极兔单号认得出", TaobaoScreenFocus.looksLikeTrackingNumber("JT3177669884834"))
    check("顺丰纯数字单号认得出", TaobaoScreenFocus.looksLikeTrackingNumber("SF1234567890123"))
    check("纯数字 12 位以上算单号", TaobaoScreenFocus.looksLikeTrackingNumber("123456789012"))
    check("一行里夹着单号也认得出",
          TaobaoScreenFocus.looksLikeTrackingNumber("运单号 JT3177669884834"))
    check("商品名不算单号", !TaobaoScreenFocus.looksLikeTrackingNumber("樱花橡皮 4B"))
    check("短数字不算单号", !TaobaoScreenFocus.looksLikeTrackingNumber("2024"))
    check("价格不算单号", !TaobaoScreenFocus.looksLikeTrackingNumber("¥19.90"))
}
do {
    // 页面框架词：这些"每一屏都有、和买了什么无关"
    check("「我的淘宝」是框架", TaobaoScreenFocus.isChrome("我的淘宝"))
    check("「查看物流」是框架", TaobaoScreenFocus.isChrome("查看物流"))
    check("「合计」是框架", TaobaoScreenFocus.isChrome("合计"))
    check("「猜你喜欢」是框架", TaobaoScreenFocus.isChrome("猜你喜欢"))
    check("价格是框架", TaobaoScreenFocus.isChrome("¥19.90"))
    check("日期是框架", TaobaoScreenFocus.isChrome("2024-05-01"))
    check("纯数字是框架", TaobaoScreenFocus.isChrome("123456"))
    check("单字是框架", TaobaoScreenFocus.isChrome("全"))
    check("「共 3 件」是框架", TaobaoScreenFocus.isChrome("共 3 件"))
    check("「第 2 页」是框架", TaobaoScreenFocus.isChrome("第 2 页"))

    // ⚠️ 这几条是**不能误杀**的：它们都是真商品
    check("「樱花橡皮」不是框架", !TaobaoScreenFocus.isChrome("樱花橡皮"))
    check("「温莎牛顿 白」不是框架", !TaobaoScreenFocus.isChrome("温莎牛顿 白"))
    check("「4K 素描纸」不是框架", !TaobaoScreenFocus.isChrome("4K 素描纸"))
    check("「马利牌水粉颜料」不是框架", !TaobaoScreenFocus.isChrome("马利牌水粉颜料"))
    check("「橡皮」不是框架（别把商品名里的词当界面词）",
          !TaobaoScreenFocus.isChrome("橡皮"))
}
do {
    let dictionary = [("樱花橡皮", TaobaoScreenFocus.normalize("樱花橡皮")),
                      ("温莎牛顿白", TaobaoScreenFocus.normalize("温莎牛顿白")),
                      ("群青", TaobaoScreenFocus.normalize("群青"))]

    // ① 标题里带已知名字 → 用**正确写法**替换
    eq("标题里带已知名 → 换成正确写法",
       TaobaoScreenFocus.bestMatch(for: "日本樱花橡皮 4B 大号", dictionary: dictionary),
       "樱花橡皮")
    // ② OCR 只认出一部分 → 仍能对上
    eq("认出半截也能对上",
       TaobaoScreenFocus.bestMatch(for: "樱花橡", dictionary: dictionary),
       "樱花橡皮")
    // ③ 形近字纠错
    eq("形近字（牛/午）能纠正",
       TaobaoScreenFocus.bestMatch(for: "温莎午顿白", dictionary: dictionary),
       "温莎牛顿白")
    // ④ 对不上就返回 nil，不能硬塞
    eq("完全不相干的返回 nil",
       TaobaoScreenFocus.bestMatch(for: "马利牌素描纸", dictionary: dictionary), nil)
    // ⑤ 太短的一截不能命中（"白"不该命中"温莎牛顿白"）
    eq("一个字不命中长名字",
       TaobaoScreenFocus.bestMatch(for: "白", dictionary: dictionary), nil)
}
do {
    // 整屏走一遍：这是用户实际会看到的那个结果
    let screen = [
        "我的淘宝", "已买到的宝贝", "全部", "待收货",
        "日本樱花橡皮 4B 大号 学生用", "¥3.50", "数量 2", "合计", "¥7.00",
        "查看物流", "确认收货", "2024-05-01 12:30",
        "温莎午顿白 补充装 60ml", "¥28.00",
        "JT3177669884834", "快递运输中",
        "猜你喜欢", "马利牌 24 色水粉颜料套装", "¥99.00",
    ]
    let result = TaobaoScreenFocus.focus(screen, knownNames: ["樱花橡皮", "温莎牛顿白"])

    check("认出了库里的两样东西",
          result.matchedNames == ["樱花橡皮", "温莎牛顿白"],
          "\(result.matchedNames)")
    check("形近字被纠回正确写法",
          result.lines.contains("温莎牛顿白"), "\(result.lines)")
    check("快递单号留下了",
          result.lines.contains("JT3177669884834"), "\(result.lines)")
    check("库里没有的新东西也留下了（马利牌套装）",
          result.lines.contains { $0.contains("马利牌") }, "\(result.lines)")
    check("「我的淘宝」这类框架被丢掉",
          !result.lines.contains("我的淘宝"))
    check("价格被丢掉", !result.lines.contains { $0.contains("¥") })
    check("日期被丢掉", !result.lines.contains { $0.contains("2024-05-01") })
    check("三样真商品一个都没漏",
          result.lines.contains { $0.contains("樱花橡皮") }
            && result.lines.contains { $0.contains("温莎牛顿白") }
            && result.lines.contains { $0.contains("马利牌") },
          "\(result.lines)")
    check("物流状态不是商品（被丢掉）", !result.lines.contains("快递运输中"),
          "\(result.lines)")
    check("「数量 2」这种标签不是商品", !result.lines.contains("数量 2"),
          "\(result.lines)")
}
do {
    // 没有词典时也要能工作（用户库还空着）
    let result = TaobaoScreenFocus.focus(
        ["我的淘宝", "樱花橡皮 4B", "¥3.50"], knownNames: []
    )
    check("没有词典时不崩、也不空", !result.lines.isEmpty)
    check("没有词典时商品名照样留下", result.lines.contains { $0.contains("樱花橡皮") })
    check("没有词典时框架照样被丢掉", !result.lines.contains("我的淘宝"))
}
do {
    // 去重：同一屏里重复出现的商品只留一条
    let result = TaobaoScreenFocus.focus(
        ["樱花橡皮 4B", "樱花橡皮 4B"], knownNames: ["樱花橡皮"]
    )
    eq("重复的商品只留一条", result.lines.count, 1)
}
do {
    // 相似度本身
    eq("完全一样 → 1", TaobaoScreenFocus.similarity("樱花橡皮", "樱花橡皮"), 1.0)
    // 5 个字里错 1 个 → LCS 4 → 2*4/10 = 0.8，正好压住 0.75 的门槛
    eq("五个字错一个 → 0.8",
       TaobaoScreenFocus.similarity("温莎午顿白", "温莎牛顿白"), 0.8)
    check("但不是 1（说明确实在判相似而不是判相等）",
          TaobaoScreenFocus.similarity("温莎午顿白", "温莎牛顿白") < 1.0)
    check("不相干的相似度很低",
          TaobaoScreenFocus.similarity("素描纸", "樱花橡皮") < 0.4)
    eq("和空串相似度为 0", TaobaoScreenFocus.similarity("", "樱花橡皮"), 0.0)
}

print("\n═══════════════════════════════════════════════════════")
print("通过 \(passed)  失败 \(failed)")
exit(failed == 0 ? 0 : 1)
