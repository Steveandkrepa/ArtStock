//
//  StockPlan 回归测试
//
//  "该不该买"算错了，用户会重复购买或者漏买 —— 而且他自己不会知道。
//  这一套把结论逻辑钉死。
//
//  用法：./scripts/run-stock-tests.sh
//

import Foundation

var passed = 0
var failed = 0

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { passed += 1; print("  ✅ \(label)") }
    else { failed += 1; print("  ❌ \(label)\(detail().isEmpty ? "" : "  → \(detail())")") }
}

func eq(_ label: String, _ actual: String, _ expected: String) {
    check(label, actual == expected, "实际「\(actual)」期望「\(expected)」")
}

// ═══ 1. 该不该补 ═══
print("═══ 1. 该不该补 ═══")
check("用完了 → 该补",
      StockPlan.needsRestock(SupplySnapshot(name: "橡皮", quantity: 0, unit: "块")))
check("负数也当用完",
      StockPlan.needsRestock(SupplySnapshot(name: "橡皮", quantity: -1, unit: "块")))
check("没设提醒线、还有货 → 不补",
      !StockPlan.needsRestock(SupplySnapshot(name: "纸", quantity: 50, lowThreshold: 0)))
check("没设提醒线、少量剩余 → 也不补（尊重用户不想被打扰的选择）",
      !StockPlan.needsRestock(SupplySnapshot(name: "纸", quantity: 1, lowThreshold: 0)))
check("设了线、到线了 → 补",
      StockPlan.needsRestock(SupplySnapshot(name: "纸", quantity: 5, lowThreshold: 5)))
check("设了线、到线下了 → 补",
      StockPlan.needsRestock(SupplySnapshot(name: "纸", quantity: 2, lowThreshold: 5)))
check("设了线、还在线上 → 不补",
      !StockPlan.needsRestock(SupplySnapshot(name: "纸", quantity: 6, lowThreshold: 5)))
check("设了线但数量为 0 → 补（用完优先）",
      StockPlan.needsRestock(SupplySnapshot(name: "纸", quantity: 0, lowThreshold: 5)))

// ═══ 2. 数量文案 ═══
print("\n═══ 2. 数量文案 ═══")
eq("整数不带小数点", StockPlan.quantityText(SupplySnapshot(name: "纸", quantity: 3, unit: "张")), "3 张")
eq("小数保留一位", StockPlan.quantityText(SupplySnapshot(name: "胶带", quantity: 2.5, unit: "卷")), "2.5 卷")
eq("0 也正常显示", StockPlan.quantityText(SupplySnapshot(name: "纸", quantity: 0, unit: "张")), "0 张")
eq("接近整数的小数当整数（避免 3.0000001 张）",
   StockPlan.quantityText(SupplySnapshot(name: "纸", quantity: 2.99999, unit: "张")), "3 张")

// ═══ 3. 原因 ═══
print("\n═══ 3. 为什么该补 ═══")
eq("用完的说法",
   StockPlan.reason(for: SupplySnapshot(name: "橡皮", quantity: 0, unit: "块")),
   "已经用完了")
do {
    let reason = StockPlan.reason(for: SupplySnapshot(name: "纸", quantity: 3, unit: "张", lowThreshold: 5))
    check("低于提醒线会说清剩多少和线在哪",
          reason.contains("3 张") && reason.contains("5"), reason)
}
do {
    let reason = StockPlan.reason(for: SupplySnapshot(name: "纸", quantity: 1, unit: "张", lowThreshold: 0))
    check("没设线时只说剩多少，不提线", !reason.contains("线"), reason)
}

// ═══ 4. 列表 ═══
print("\n═══ 4. 该补清单 ═══")
do {
    let supplies = [
        SupplySnapshot(name: "4K 素描纸", categoryName: "纸张", categoryOrder: 0,
                       quantity: 0, unit: "张", lowThreshold: 10),
        SupplySnapshot(name: "樱花橡皮", categoryName: "橡皮", categoryOrder: 2,
                       quantity: 1, unit: "块", lowThreshold: 2),
        SupplySnapshot(name: "美纹纸胶带", categoryName: "胶带", categoryOrder: 3,
                       quantity: 8, unit: "卷", lowThreshold: 2),
        SupplySnapshot(name: "2B 铅笔", categoryName: "笔", categoryOrder: 1,
                       quantity: 12, unit: "支", lowThreshold: 0),
        SupplySnapshot(name: "16K 水彩纸", categoryName: "纸张", categoryOrder: 0,
                       quantity: 2, unit: "本", lowThreshold: 1)
    ]
    let lines = StockPlan.restockLines(from: supplies)
    check("只挑出该补的 2 项", lines.count == 2, "\(lines.count)：\(lines.map(\.name))")
    check("纸张（序号 0）排在橡皮（序号 2）前面",
          lines.first?.categoryName == "纸张", lines.first?.categoryName ?? "nil")
    check("数量文案进了清单", lines.contains { $0.quantityText == "1 块" },
          lines.map(\.quantityText).joined(separator: ", "))
    check("原因也进了清单", lines.allSatisfy { !$0.reason.isEmpty },
          lines.map(\.reason).joined(separator: " | "))
}
do {
    // 顺序必须稳定 —— 每次进来顺序都在跳，用户会以为列表变了
    let supplies = (0..<12).map {
        SupplySnapshot(name: "耗材\($0)", categoryName: "其他", categoryOrder: 4,
                       quantity: 0, unit: "个")
    }
    let first = StockPlan.restockLines(from: supplies).map(\.name)
    let second = StockPlan.restockLines(from: supplies.reversed()).map(\.name)
    check("输入顺序变了，输出顺序不变", first == second, "\(first) vs \(second)")
}
check("空列表 → 空清单", StockPlan.restockLines(from: []).isEmpty)
check("都不该补 → 空清单",
      StockPlan.restockLines(from: [SupplySnapshot(name: "纸", quantity: 99)]).isEmpty)
do {
    // 不能把多行字面量塞进字符串插值里 —— Swift 不允许跨行的 "\(" 字符串
    let counted = StockPlan.restockCount(in: [
        SupplySnapshot(name: "A", quantity: 0),
        SupplySnapshot(name: "B", quantity: 1, lowThreshold: 2),
        SupplySnapshot(name: "C", quantity: 5)
    ])
    check("计数正确（2 项该补）", counted == 2, "\(counted)")
}

// ═══ 5. 统一结论（这次改动的重点）═══
print("\n═══ 5. 颜料 + 耗材 的统一结论 ═══")
eq("两边都空",
   StockPlan.summary(paintColors: 0, paintUnits: 0, supplies: []),
   "颜料和耗材都够用，暂时什么都不用买。")
eq("只有颜料缺",
   StockPlan.summary(paintColors: 3, paintUnits: 4, supplies: []),
   "该买：颜料缺 3 个颜色（共 4 件）。")
eq("只有耗材缺",
   StockPlan.summary(paintColors: 0, paintUnits: 0,
                     supplies: [SupplySnapshot(name: "纸", quantity: 0)]),
   "该买：耗材有 1 项该补。")
eq("两边都缺 —— 要一句话说全",
   StockPlan.summary(paintColors: 2, paintUnits: 3,
                     supplies: [SupplySnapshot(name: "纸", quantity: 0),
                                SupplySnapshot(name: "橡皮", quantity: 1, lowThreshold: 2)]),
   "该买：颜料缺 2 个颜色（共 3 件）；耗材有 2 项该补。")
check("耗材只算该补的，不算全部",
      StockPlan.summary(paintColors: 0, paintUnits: 0, supplies: [
          SupplySnapshot(name: "A", quantity: 99),
          SupplySnapshot(name: "B", quantity: 0)
      ]).contains("1 项"))
check("两边都不缺 → isEmpty",
      StockPlan.isEmpty(paintColors: 0, supplies: [SupplySnapshot(name: "A", quantity: 99)]))
check("有一边缺 → 不 isEmpty",
      !StockPlan.isEmpty(paintColors: 1, supplies: []))
check("耗材缺 → 不 isEmpty",
      !StockPlan.isEmpty(paintColors: 0, supplies: [SupplySnapshot(name: "A", quantity: 0)]))

// ═══ 6. 余量档位（这次耗材重做的核心）═══
print("\n═══ 6. 余量档位：跟颜料盒同一套语言 ═══")
do {
    // 设了满量 → 按比例分档
    func level(_ q: Double, full: Double) -> String {
        StockPlan.level(quantity: q, fullCapacity: full, lowThreshold: 0).rawValue
    }
    eq("0 → 用完", level(0, full: 100), "out")
    eq("5/100 → 快没了", level(5, full: 100), "low")
    eq("14/100 → 快没了（临界）", level(14, full: 100), "low")
    eq("15/100 → 剩一半", level(15, full: 100), "half")
    eq("49/100 → 剩一半", level(49, full: 100), "half")
    eq("50/100 → 够用", level(50, full: 100), "okay")
    eq("79/100 → 够用", level(79, full: 100), "okay")
    eq("80/100 → 充足", level(80, full: 100), "plenty")
    eq("满 → 充足", level(100, full: 100), "plenty")
    eq("超过满量也算充足", level(150, full: 100), "plenty")
}
do {
    // 没设满量 → 退回提醒线
    func level(_ q: Double, threshold: Double) -> String {
        StockPlan.level(quantity: q, fullCapacity: 0, lowThreshold: threshold).rawValue
    }
    eq("没满量、到提醒线 → 快没了", level(3, threshold: 3), "low")
    eq("没满量、高于线 → 剩一半", level(5, threshold: 3), "half")
    eq("没满量、远高于线 → 够用", level(20, threshold: 3), "okay")
    eq("数量和线都是 0 → 用完优先", level(0, threshold: 0), "out")
}
do {
    // 什么都没设：**刻意不猜**
    let noInfo = StockPlan.level(quantity: 1, fullCapacity: 0, lowThreshold: 0)
    eq("没设满量也没设提醒线 → 只报够用，不编一个「快没了」", noInfo.rawValue, "okay")
    let zeroNoInfo = StockPlan.level(quantity: 0, fullCapacity: 0, lowThreshold: 0)
    eq("但真的用完了照样报用完", zeroNoInfo.rawValue, "out")
}
do {
    check("只有用完与快没了需要动手",
          SupplyLevel.out.needsAttention && SupplyLevel.low.needsAttention
          && !SupplyLevel.half.needsAttention && !SupplyLevel.okay.needsAttention
          && !SupplyLevel.plenty.needsAttention)
    check("余量条比例随档位递增",
          SupplyLevel.out.barFraction < SupplyLevel.low.barFraction
          && SupplyLevel.low.barFraction < SupplyLevel.half.barFraction
          && SupplyLevel.half.barFraction < SupplyLevel.okay.barFraction
          && SupplyLevel.okay.barFraction < SupplyLevel.plenty.barFraction)
    check("五个档位都有中文名",
          SupplyLevel.allCases.allSatisfy { !$0.displayName.isEmpty })
}
do {
    // 注意：这个文件里的 eq 是 String 版，比例要用 check 比
    func fraction(_ q: Double, _ full: Double) -> Double? {
        StockPlan.remainingFraction(quantity: q, fullCapacity: full)
    }
    check("比例：50/100 = 0.5", abs((fraction(50, 100) ?? -1) - 0.5) < 1e-9,
          "\(fraction(50, 100) ?? -1)")
    check("比例：超过满量会夹到 1", fraction(150, 100) == 1.0, "\(fraction(150, 100) ?? -1)")
    check("比例：负数夹到 0", fraction(-5, 100) == 0.0, "\(fraction(-5, 100) ?? -1)")
    check("比例：刚好为 0", fraction(0, 100) == 0.0, "\(fraction(0, 100) ?? -1)")
    check("没设满量时不给比例（不编）", fraction(5, 0) == nil)
}


// ═══ 8. 预计到达时间 ═══
print("\n═══ 8. 预计到达时间 ═══")
do {
    let cal = Calendar(identifier: .gregorian)
    let now = cal.date(from: DateComponents(year: 2025, month: 6, day: 12))!
    func days(_ add: Int) -> Date {
        cal.date(byAdding: .day, value: add, to: now)!
    }
    check("今天 = 0 天", ArrivalEstimate.daysUntil(days(0), from: now, calendar: cal) == 0)
    check("明天 = 1 天", ArrivalEstimate.daysUntil(days(1), from: now, calendar: cal) == 1)
    check("三天后 = 3 天", ArrivalEstimate.daysUntil(days(3), from: now, calendar: cal) == 3)
    check("昨天 = -1 天", ArrivalEstimate.daysUntil(days(-1), from: now, calendar: cal) == -1)

    eq("没设 → 到货时间未设", ArrivalEstimate.text(for: nil, from: now, calendar: cal), "到货时间未设")
    eq("今天到", ArrivalEstimate.text(for: days(0), from: now, calendar: cal), "预计今天到")
    eq("明天到", ArrivalEstimate.text(for: days(1), from: now, calendar: cal), "预计明天到")
    eq("三天后到", ArrivalEstimate.text(for: days(3), from: now, calendar: cal), "预计 3 天后到")
    eq("超期两天", ArrivalEstimate.text(for: days(-2), from: now, calendar: cal), "已超预计 2 天")
    eq("超期一天", ArrivalEstimate.text(for: days(-1), from: now, calendar: cal), "预计昨天到")
    eq("已收到就不谈几天到",
       ArrivalEstimate.text(for: days(3), from: now, isReceived: true, calendar: cal), "已收到")
    eq("超过 7 天带上日期", ArrivalEstimate.text(for: days(20), from: now, calendar: cal), "预计 20 天后到（7/2）")
}
do {
    check("中位数：奇数个取中间", ArrivalEstimate.learnedLeadDays(history: [1, 2, 3]) == 2)
    check("中位数：偶数个取中间平均（2.5 → 3）", ArrivalEstimate.learnedLeadDays(history: [1, 2, 3, 4]) == 3)
    check("样本少于 2 → 退回默认", ArrivalEstimate.learnedLeadDays(history: [2]) == 3)
    check("空历史 → 退回默认", ArrivalEstimate.learnedLeadDays(history: []) == 3)
    check("自定义兜底", ArrivalEstimate.learnedLeadDays(history: [], fallback: 5) == 5)
    check("异常值被排除（60 天以上）",
       ArrivalEstimate.learnedLeadDays(history: [1, 1, 90]) == 1)
    check("负数被排除（剩 [2,4] → 3）", ArrivalEstimate.learnedLeadDays(history: [2, -3, 4]) == 3)
}
do {
    // ⚠️ 这一组是修一个真实 bug 加的：以前样本不够会"退回默认 3 天"，
    //    于是把一个**已经到货**的快递单号录进来，界面显示"预计 3 天后到"——
    //    那个 3 天是编的。现在估不出来就必须说估不出来。
    //    （这个文件里的 eq 只吃字符串，所以可选值用 check 比。）
    check("没有历史 → nil（不编）", ArrivalEstimate.leadDays(history: []) == nil)
    check("只有 1 次记录 → nil（一次可能只是巧合）",
          ArrivalEstimate.leadDays(history: [2]) == nil)
    check("2 次记录才开始推算", ArrivalEstimate.leadDays(history: [2, 4]) == 3)
    check("3 次取中位数", ArrivalEstimate.leadDays(history: [1, 5, 9]) == 5)
    check("全是异常值 → 等于没历史", ArrivalEstimate.leadDays(history: [90, -1]) == nil)
    check("只剩 1 个有效值 → nil", ArrivalEstimate.leadDays(history: [3, 90]) == nil)
    check("下限可调（只要 1 次也能算）",
          ArrivalEstimate.leadDays(history: [7], minimum: 1) == 7)
    check("至少两次是默认规则", ArrivalEstimate.minimumHistoryForEstimate == 2)
    // 想要数字的调用方自己承担"这是编的"
    check("learnedLeadDays 仍然给数字", ArrivalEstimate.learnedLeadDays(history: []) == 3)
}

// ═══ 9. 在途抵扣（采购结论的核心）═══
print("\n═══ 9. 在途抵扣 ═══")
func supply(_ isColor: Bool, _ code: String, _ kind: RefillKind?, _ qty: Int, _ days: Int? = nil)
    -> IncomingSupply {
    let arrival: Date?
    if let days {
        arrival = Calendar.current.date(byAdding: .day, value: days, to: Date())
    } else {
        arrival = nil
    }
    return IncomingSupply(
        isColor: isColor, code: code, refillKind: kind, quantity: qty,
        estimatedArrival: arrival, packageID: "P")
}
do {
    check("颜色+类型匹配",
          supply(true, "PRESET-35", .squeeze, 2).coversColor(code: "PRESET-35", kind: .squeeze))
    check("类型未定也能抵（用户还没说是挤出还是替换）",
          supply(true, "PRESET-35", nil, 2).coversColor(code: "PRESET-35", kind: .squeeze))
    check("颜色不同不匹配",
          !supply(true, "PRESET-35", .squeeze, 2).coversColor(code: "PRESET-01", kind: .squeeze))
    check("类型明确且不同则不匹配（加了挤出装抵不了替换装的缺口）",
          !supply(true, "PRESET-35", .pan, 2).coversColor(code: "PRESET-35", kind: .squeeze))
    check("耗材按名匹配",
          supply(false, "樱花橡皮", nil, 2).coversSupply(named: "樱花橡皮"))
    check("耗材不跨类", !supply(false, "樱花橡皮", nil, 2).coversColor(code: "X", kind: nil))
}
do {
    let noIncoming: [IncomingSupply] = []
    let plain = StockPlan.netShortage(shortage: 3, incoming: noIncoming)
    check("没有在途 → 原样", plain.stillNeeded == 3, "\(plain.stillNeeded)")
    check("覆盖 0", plain.coveredBy == 0, "\(plain.coveredBy)")
    check("没有最早到达", plain.earliestArrival == nil)
}
do {
    let half = StockPlan.netShortage(
        shortage: 3,
        incoming: [supply(true, "P", .squeeze, 1), supply(true, "P", .squeeze, 1)]
    )
    check("在途 2 件抵掉缺口 3 的 2", half.stillNeeded == 1, "\(half.stillNeeded)")
    check("覆盖 2 件", half.coveredBy == 2, "\(half.coveredBy)")
}
do {
    let full = StockPlan.netShortage(
        shortage: 2,
        incoming: [supply(true, "P", .squeeze, 3)]
    )
    check("在途充足 → 不用买", full.stillNeeded == 0, "\(full.stillNeeded)")
    check("覆盖到缺口上限", full.coveredBy == 2, "\(full.coveredBy)")
}
do {
    // 最早到达时间取在途里最早的
    let cal = Calendar(identifier: .gregorian)
    let now = cal.date(from: DateComponents(year: 2025, month: 6, day: 12))!
    func arriving(_ days: Int) -> Date { cal.date(byAdding: .day, value: days, to: now)! }
    let result = StockPlan.netShortage(
        shortage: 5,
        incoming: [
            IncomingSupply(isColor: true, code: "P", refillKind: .squeeze, quantity: 2,
                           estimatedArrival: arriving(4), packageID: "A"),
            IncomingSupply(isColor: true, code: "P", refillKind: .squeeze, quantity: 2,
                           estimatedArrival: arriving(1), packageID: "B"),
            IncomingSupply(isColor: true, code: "P", refillKind: .squeeze, quantity: 2,
                           estimatedArrival: arriving(2), packageID: "C")
        ],
        now: now
    )
    check("覆盖到缺口上限（6 件在途、缺 5 → 覆盖 5）", result.coveredBy == 5, "\(result.coveredBy)")
    check("最早的在途是 1 天后",
          result.earliestArrival == arriving(1),
          result.earliestArrival.map { "\($0)" } ?? "nil")
}
do {
    do {
        let r = StockPlan.netShortage(shortage: 0, incoming: [supply(true, "P", .squeeze, 5)])
        check("缺口为 0 → 全零",
              r.stillNeeded == 0 && r.coveredBy == 0 && r.earliestArrival == nil,
              "\(r.stillNeeded)/\(r.coveredBy)")
    }
}

print("\n═══════════════════════════════════════════════════════")
print("通过 \(passed)  失败 \(failed)")
exit(failed == 0 ? 0 : 1)
