//
//  收包裹解析测试
//
//  这一类解析错了的后果很具体：把**手机号**、**淘宝订单号（19 位）**、
//  **价格**当成快递单号记下来，用户点"入库"时才发现 —— 而且他不会怀疑解析器。
//  所以测试里塞的都是真实的脏文本形态。
//
//  S10 校验位那几条是用**公开算法**算出来的：
//  前 8 位数字按权重 8,6,4,2,3,5,9,7 加权求和，11 - (和 mod 11)，
//  10 归 0，11 归 5。所以 EA123456785CN 合法、EA123456789CN 不合法。
//
//  用法：./scripts/run-package-tests.sh
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

// ═══ 1. S10 校验位（唯一有国际标准的单号格式）═══
print("═══ 1. 万国邮联 S10 校验位 ═══")
check("EA123456785CN 合法（校验位 5）", TrackingNumberParser.isValidUPU_S10("EA123456785CN"))
check("EA123456789CN 不合法（校验位应为 5 不是 9）",
      !TrackingNumberParser.isValidUPU_S10("EA123456789CN"))
check("小写也认", TrackingNumberParser.isValidUPU_S10("ea123456785cn"))
check("位数不对不认", !TrackingNumberParser.isValidUPU_S10("EA123456785C"))
check("数字位置不对不认", !TrackingNumberParser.isValidUPU_S10("E1123456785CN"))
check("国家码不是字母不认", !TrackingNumberParser.isValidUPU_S10("EA12345678511"))
check("空串不崩", !TrackingNumberParser.isValidUPU_S10(""))

// ═══ 2. 承运商推断（宁缺勿滥）═══
print("\n═══ 2. 承运商推断 ═══")
do {
    let sf = TrackingNumberParser.inferCarrier("SF1234567890123")
    eq("SF 开头 → 顺丰", sf?.carrier, "顺丰速运")
    eq("标为较可能（前缀明确但无校验位）", sf?.confidence, .likely)
    check("给出了判断依据", sf?.evidence.contains("SF") == true, sf?.evidence ?? "nil")
}
eq("JD 开头 → 京东", TrackingNumberParser.inferCarrier("JD1234567890")?.carrier, "京东物流")
eq("JT 开头 → 极兔", TrackingNumberParser.inferCarrier("JT1234567890123")?.carrier, "极兔速递")
eq("YT 开头 → 圆通", TrackingNumberParser.inferCarrier("YT1234567890123")?.carrier, "圆通速递")
eq("DOP 开头 → 德邦", TrackingNumberParser.inferCarrier("DOP1234567890")?.carrier, "德邦快递")
do {
    let ems = TrackingNumberParser.inferCarrier("EA123456785CN")
    eq("S10 合法 → 中国邮政", ems?.carrier, "中国邮政 / EMS")
    eq("有校验位支撑 → 确定", ems?.confidence, .certain)
}
do {
    let intl = TrackingNumberParser.inferCarrier("EA123456785US")
    eq("非 CN 国家码 → 国际邮政", intl?.carrier, "国际邮政（US）")
}
// 前缀后面必须跟数字，否则 JDD / SFX 这种会误判
check("SF 后面不是数字就不认",
      TrackingNumberParser.inferCarrier("SFABC1234567") == nil)
do {
    let zto = TrackingNumberParser.inferCarrier("751234567890")
    eq("12 位 75 开头 → 中通（猜测）", zto?.carrier, "中通快递")
    eq("标为猜测", zto?.confidence, .guess)
}
do {
    let yd = TrackingNumberParser.inferCarrier("3123456789012")
    eq("13 位 3 开头 → 韵达（猜测）", yd?.carrier, "韵达速递")
    eq("猜的就是猜的", yd?.confidence, .guess)
}
check("认不出的纯数字返回 nil（不编一个）",
      TrackingNumberParser.inferCarrier("999999999999") == nil)
check("纯字母返回 nil", TrackingNumberParser.inferCarrier("ABCDEFGHIJ") == nil)

// ═══ 3. 从脏文本里挑单号（关键在排除）═══
print("\n═══ 3. 从脏文本里挑单号 ═══")
do {
    let text = """
    订单号: 3821947562019487562
    收货人: 张某某 13812345678
    收货地址: 某某省某某市某某区某某路 1 号
    物流公司: 顺丰速运
    快递单号: SF1234567890123
    实付: ¥68.00
    """
    let numbers = TrackingNumberParser.candidates(in: text).map(\.number)
    check("认出了顺丰单号", numbers.contains("SF1234567890123"), "\(numbers)")
    check("手机号没被当成单号", !numbers.contains("13812345678"), "\(numbers)")
    check("淘宝订单号没被当成单号", !numbers.contains("3821947562019487562"), "\(numbers)")
    eq("只留下 1 个候选", numbers.count, 1)
}
do {
    // 裸单号（最常见的用法：用户只输一个单号）
    eq("裸单号能认", TrackingNumberParser.candidates(in: "YT1234567890123").first?.number,
       "YT1234567890123")
    eq("裸纯数字能认", TrackingNumberParser.candidates(in: "751234567890").count, 1)
}
do {
    // 各种不该认的
    let text = "13812345678\n20250612\n38.50\nabcdefgh\n1\n订单号 123456789012345678"
    let numbers = TrackingNumberParser.candidates(in: text).map(\.number)
    check("手机号被排除", !numbers.contains("13812345678"), "\(numbers)")
    check("日期被排除（20250612）", !numbers.contains("20250612"), "\(numbers)")
    check("纯字母被排除", !numbers.contains("ABCDEFGH"), "\(numbers)")
    check("19 位订单号被排除（超 15 位纯数字）",
          !numbers.contains("123456789012345678"), "\(numbers)")
}
do {
    // 带连字符/空格的单号（快递短信常见写法）
    let numbers = TrackingNumberParser.candidates(in: "单号 SF-1234 5678 90123 请查收").map(\.number)
    check("分段写的单号能被拼回来", numbers.contains("SF1234567890123"), "\(numbers)")
}
do {
    // 中文不能被并进单号（汉字在 Unicode 里也算 letter，第一版就栽在这）
    let numbers = TrackingNumberParser.candidates(in: "单号SF1234567890123请查收").map(\.number)
    check("中文没被并进单号", numbers.contains("SF1234567890123"), "\(numbers)")
    check("没有产生带中文的候选",
          !numbers.contains { $0.contains { !$0.isASCII } }, "\(numbers)")
}
do {
    // 置信度排序：确定的排前面
    let text = "751234567890\nSF1234567890123\nEA123456785CN"
    let candidates = TrackingNumberParser.candidates(in: text)
    eq("确定/较可能的排在猜测前面", candidates.first?.confidence, .certain)
}
check("空文本返回空", TrackingNumberParser.candidates(in: "").isEmpty)

// ═══ 4. 订单文本解析 ═══
print("\n═══ 4. 订单文本 → 商品清单 ═══")
do {
    let text = """
    马利牌水粉颜料补充装 群青 5ml x2
    马利牌水粉颜料替换装 钛白 x1
    樱花橡皮 2件
    4K素描纸 1包
    """
    let parsed = OrderTextParser.parse(text)
    eq("解析出 4 个商品", parsed.items.count, 4)
    eq("第一个商品名", parsed.items.first?.name, "马利牌水粉颜料补充装 群青 5ml")
    eq("x2 被认成数量 2", parsed.items.first?.quantity, 2)
    eq("x1 是 1", parsed.items[1].quantity, 1)
    eq("「2件」被认成数量 2", parsed.items[2].quantity, 2)
    eq("「1包」被认成数量 1", parsed.items[3].quantity, 1)
}
do {
    // 数量写法的各种变体
    let cases: [(String, Int)] = [
        ("群青补充装 x3", 3),
        ("群青补充装 X3", 3),
        ("群青补充装 ×3", 3),
        ("群青补充装 *3", 3),
        ("群青补充装 数量：3", 3),
        ("群青补充装 数量:3", 3),
        ("群青补充装 3支", 3),
        ("群青补充装 3个", 3),
        ("群青补充装 3盒", 3)
    ]
    for (line, expected) in cases {
        let item = OrderTextParser.makeItem(from: line)
        eq("「\(line)」→ 数量 \(expected)", item?.quantity, expected)
    }
}
do {
    // 价格与括号要被清掉，但商品名要留下
    let item = OrderTextParser.makeItem(from: "马利水粉 群青 5ml ¥12.80 x2")
    check("价格被清掉", item?.name.contains("12.80") == false, item?.name ?? "nil")
    check("价格符号被清掉", item?.name.contains("¥") == false, item?.name ?? "nil")
    check("商品名还在", item?.name.contains("群青") == true, item?.name ?? "nil")
    eq("数量仍正确", item?.quantity, 2)
}
do {
    let item = OrderTextParser.makeItem(from: "素描纸（4K 加厚）1包")
    check("括号备注被清掉", item?.name.contains("加厚") == false, item?.name ?? "nil")
    check("名称还在", item?.name.contains("素描纸") == true, item?.name ?? "nil")
}
do {
    // 非商品行必须被排除
    let text = """
    订单号: 3821947562019487562
    下单时间: 2025-06-12 20:30
    实付: ¥68.00
    收货人: 张某某
    物流公司: 顺丰速运
    快递单号: SF1234567890123
    """
    let parsed = OrderTextParser.parse(text)
    eq("这些行一个商品都不该产生", parsed.items.count, 0)
    eq("但单号认出来了", parsed.trackingNumber, "SF1234567890123")
    eq("承运商也认出来了", parsed.carrier, "顺丰速运")
}
do {
    // 纯数字行与短行
    eq("单字符行不算商品", OrderTextParser.makeItem(from: "2"), nil)
    check("纯符号行不算商品", OrderTextParser.makeItem(from: "———") == nil)
    check("空行不算商品", OrderTextParser.makeItem(from: "   ") == nil)
}
do {
    // 重复商品名只留一个
    let text = "群青补充装 x2\n群青补充装 x2"
    eq("重复行去重", OrderTextParser.parse(text).items.count, 1)
}
do {
    let empty = OrderTextParser.parse("")
    check("空文本不崩且为空", empty.isEmpty)
    eq("没有单号", empty.trackingNumber, nil)
}

// ═══ 5. 补充装类型推断 ═══
print("\n═══ 5. 从商品名看补充装类型 ═══")
eq("「补充装」→ 挤出", PackageItemMatcher.inferRefillKind(from: "群青补充装"), .squeeze)
eq("「软管」→ 挤出", PackageItemMatcher.inferRefillKind(from: "群青软管装"), .squeeze)
eq("「挤压」→ 挤出", PackageItemMatcher.inferRefillKind(from: "群青挤压式"), .squeeze)
eq("「替换装」→ 直接替换", PackageItemMatcher.inferRefillKind(from: "群青替换装"), .pan)
eq("「色块」→ 直接替换", PackageItemMatcher.inferRefillKind(from: "群青色块"), .pan)
eq("「固体」→ 直接替换", PackageItemMatcher.inferRefillKind(from: "群青固体颜料"), .pan)
check("认不出时返回 nil（不猜）",
      PackageItemMatcher.inferRefillKind(from: "群青 5ml") == nil)
check("两种关键词都在时以替换装优先",
      PackageItemMatcher.inferRefillKind(from: "替换装色块") == .pan)

// ═══ 6. 自动匹配到库 ═══
print("\n═══ 6. 自动匹配到颜色 / 耗材 ═══")
do {
    let catalog = PackageMatchCatalog.presetOnly
    let items = [
        ParsedPackageItem(name: "马利水粉补充装 群青 5ml", quantity: 2, rawLine: ""),
        ParsedPackageItem(name: "钛白替换装", quantity: 1, rawLine: ""),
        ParsedPackageItem(name: "完全无关的东西", quantity: 1, rawLine: "")
    ]
    let matched = PackageItemMatcher.match(items: items, against: catalog)
    eq("匹配出 3 条", matched.count, 3)
    if case .color(let code, let name, let kind) = matched[0].target {
        eq("群青匹配到 PRESET-35", code, "PRESET-35")
        eq("名字正确", name, "群青")
        eq("类型识别为挤出补充装", kind, .squeeze)
    } else {
        check("群青应匹配到颜色", false, "\(matched[0].target)")
    }
    if case .color(let code, _, let kind) = matched[1].target {
        eq("钛白匹配到 PRESET-01", code, "PRESET-01")
        eq("类型识别为直接替换装", kind, .pan)
    } else {
        check("钛白应匹配到颜色", false, "\(matched[1].target)")
    }
    eq("无关条目判为未匹配", matched[2].target, .unmatched)
}
do {
    // 标准号命中优先
    let catalog = PackageMatchCatalog.presetOnly
    let items = [ParsedPackageItem(name: "进口颜料 PW6 大支", quantity: 1, rawLine: "")]
    let matched = PackageItemMatcher.match(items: items, against: catalog)
    if case .color(let code, let name, _) = matched[0].target {
        eq("按 PW6 匹配到钛白", code, "PRESET-01")
        eq("名字正确", name, "钛白")
        eq("标准号命中给满分", matched[0].score, 1.0)
    } else {
        check("PW6 应匹配到钛白", false, "\(matched[0].target)")
    }
}
do {
    // 耗材匹配
    let catalog = PackageMatchCatalog(
        colors: [],
        supplies: [
            .init(name: "4K 素描纸", unit: "张"),
            .init(name: "樱花橡皮", unit: "块")
        ]
    )
    let items = [
        ParsedPackageItem(name: "4K素描纸 加厚 100张", quantity: 1, rawLine: ""),
        ParsedPackageItem(name: "樱花橡皮 大号", quantity: 2, rawLine: "")
    ]
    let matched = PackageItemMatcher.match(items: items, against: catalog)
    eq("素描纸匹配到耗材", matched[0].target, .supply(name: "4K 素描纸"))
    eq("橡皮匹配到耗材", matched[1].target, .supply(name: "樱花橡皮"))
}
do {
    // 短名字不该乱匹配
    let catalog = PackageMatchCatalog.presetOnly
    let items = [ParsedPackageItem(name: "绿", quantity: 1, rawLine: "")]
    let matched = PackageItemMatcher.match(items: items, against: catalog)
    eq("单字不匹配（避免乱认）", matched[0].target, .unmatched)
}
do {
    // 需要确认的阈值
    let catalog = PackageMatchCatalog.presetOnly
    let exact = PackageItemMatcher.match(
        items: [ParsedPackageItem(name: "群青", quantity: 1, rawLine: "")], against: catalog
    )
    check("完全一致不需要确认", exact[0].needsConfirmation == false, "\(exact[0].score)")
    let vague = PackageItemMatcher.match(
        items: [ParsedPackageItem(name: "那个蓝蓝的颜料", quantity: 1, rawLine: "")],
        against: catalog
    )
    check("模糊的不匹配或需要确认",
          vague[0].target == .unmatched || vague[0].needsConfirmation,
          "\(vague[0].target) score=\(vague[0].score)")
}

// ═══ 7. 端到端：一段真实形态的订单文本 ═══
print("\n═══ 7. 端到端 ═══")
do {
    let text = """
    订单号: 3821947562019487562
    下单时间: 2025-06-12 20:30:15
    店铺: 某某美术用品专营店
    马利牌水粉颜料补充装 群青 5ml x2  ¥12.80
    马利牌水粉颜料替换装 钛白 x1  ¥8.90
    温莎牛顿 熟褐 补充装 软管 x1
    4K素描纸 加厚 100张 1包
    实付: ¥45.30
    收货人: 张某某 13812345678
    收货地址: 某某省某某市某某区某某路 1 号
    物流公司: 顺丰速运
    快递单号: SF1234567890123
    """
    let parsed = OrderTextParser.parse(text, preferTracking: "SF1234567890123")
    eq("单号正确", parsed.trackingNumber, "SF1234567890123")
    eq("承运商正确", parsed.carrier, "顺丰速运")
    eq("商品数 4（订单号/实付/地址都不算）", parsed.items.count, 4)
    check("手机号没有混进商品", !parsed.items.contains { $0.name.contains("13812345678") })

    let matched = PackageItemMatcher.match(
        items: parsed.items, against: .presetOnly
    )
    let colors = matched.compactMap { item -> String? in
        if case .color(let code, _, _) = item.target { return code }
        return nil
    }
    check("群青、钛白、熟褐都匹配上了",
          colors.contains("PRESET-35") && colors.contains("PRESET-01") && colors.contains("PRESET-14"),
          "\(colors)")
    eq("数量：群青 2 支", matched.first?.item.quantity, 2)
}

print("\n═══════════════════════════════════════════════════════")
print("通过 \(passed)  失败 \(failed)")
exit(failed == 0 ? 0 : 1)
