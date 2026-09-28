//
//  RefillMath 回归测试
//
//  验证的是这个 App 的核心承诺：**颜料不缺，也不过多**。
//  三个算术错一个，用户要么漏买（断档）要么多买（占地方费钱），
//  所以它们被抽成纯函数放在这里逐条验证。
//
//  用法：./scripts/run-math-tests.sh
//

import Foundation

var passed = 0
var failed = 0

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { passed += 1; print("  ✅ \(label)") }
    else { failed += 1; print("  ❌ \(label)\(detail().isEmpty ? "" : "  → \(detail())")") }
}
func eqi(_ label: String, _ a: Int, _ b: Int) {
    check(label, a == b, "actual=\(a) expected=\(b)")
}
func eqs(_ label: String, _ a: ColorStockState, _ b: ColorStockState) {
    check(label, a == b, "actual=\(a) expected=\(b)")
}

// ═══════════════════════════════════════════════════════════
print("═══ 1. 缺口计算 ═══")
eqi("缺 0：够补", RefillMath.shortage(needed: 2, capacity: 3), 0)
eqi("缺 1：差一格", RefillMath.shortage(needed: 2, capacity: 1), 1)
eqi("缺 5：完全没有库存", RefillMath.shortage(needed: 5, capacity: 0), 5)
eqi("不需要补时为 0", RefillMath.shortage(needed: 0, capacity: 0), 0)

print("\n═══ 2. 该买几件（向上取整是关键）═══")
eqi("缺 4 格 / 每件补 3 格 → 必须买 2 件", RefillMath.unitsToBuy(shortage: 4, capacityPerUnit: 3), 2)
eqi("缺 3 格 / 每件补 3 格 → 正好 1 件", RefillMath.unitsToBuy(shortage: 3, capacityPerUnit: 3), 1)
eqi("缺 1 格 / 每件补 3 格 → 还是要买 1 件", RefillMath.unitsToBuy(shortage: 1, capacityPerUnit: 3), 1)
eqi("替换式：缺 5 格买 5 个", RefillMath.unitsToBuy(shortage: 5, capacityPerUnit: 1), 5)
eqi("没缺口 → 不买", RefillMath.unitsToBuy(shortage: 0, capacityPerUnit: 3), 0)
eqi("每件容量为 0 时按 1 兜底，不崩", RefillMath.unitsToBuy(shortage: 3, capacityPerUnit: 0), 3)

print("\n═══ 3. 状态判定 ═══")
eqs("没进盒子 → unassigned",
    RefillMath.state(needed: 0, capacity: 0, isAssigned: false), .unassigned)
eqs("都够 → fine",
    RefillMath.state(needed: 0, capacity: 3, isAssigned: true), .fine)
eqs("该补且库存够 → canRefill",
    RefillMath.state(needed: 2, capacity: 3, isAssigned: true), .canRefill)
eqs("该补但库存不够 → mustBuy",
    RefillMath.state(needed: 5, capacity: 1, isAssigned: true), .mustBuy)
eqs("完全不缺且库存超额 → overstocked",
    RefillMath.state(needed: 0, capacity: 12, isAssigned: true), .overstocked)
eqs("刚好到阈值不算过多",
    RefillMath.state(needed: 0, capacity: RefillMath.defaultOverstockCapacity, isAssigned: true), .fine)
eqs("超过阈值一格就算过多",
    RefillMath.state(needed: 0, capacity: RefillMath.defaultOverstockCapacity + 1, isAssigned: true), .overstocked)
eqs("还要补的时候不该报过多（该去补，不是别买）",
    RefillMath.state(needed: 1, capacity: 20, isAssigned: true), .canRefill)

print("\n═══ 4. 消耗模拟（先用已开封的，再开新的）═══")

// 4.1 整支正好够
do {
    let r = RefillMath.consume(needed: 3, units: 1, capacityPerUnit: 3, partial: 0)
    eqi("整支正好：补 3 格", r.filled, 3)
    eqi("整支正好：用 1 支", r.unitsUsed, 1)
    eqi("整支正好：开封剩余 0", r.remainingPartial, 0)
    check("整支正好：不缺", !r.wasShort)
}

// 4.2 只用已开封的就够，不该开新支
do {
    let r = RefillMath.consume(needed: 2, units: 5, capacityPerUnit: 3, partial: 2)
    eqi("只用已开封：补 2 格", r.filled, 2)
    eqi("只用已开封：一支都不开", r.unitsUsed, 0)
    eqi("只用已开封：剩余 0", r.remainingPartial, 0)
    check("只用已开封：标记 usedPartial", r.usedPartial)
}

// 4.3 已开封不够，需要开新支；新支被用满则剩余为 0
do {
    let r = RefillMath.consume(needed: 4, units: 1, capacityPerUnit: 3, partial: 1)
    eqi("已开封+新支：补 4 格", r.filled, 4)
    eqi("已开封+新支：开 1 支", r.unitsUsed, 1)
    // 已开封补 1 格 → 还需 3 格 → 新支正好用满 → 剩余 0。
    eqi("已开封+新支：新支被用满则剩余 0", r.remainingPartial, 0)
    check("已开封+新支：不缺", !r.wasShort)
}

// 4.3b 新支没用满时要正确留下剩余（这才是"不过多"依赖的部分）
do {
    let r = RefillMath.consume(needed: 2, units: 1, capacityPerUnit: 3, partial: 1)
    eqi("新支用掉 1 格：共补 2 格", r.filled, 2)
    eqi("新支用掉 1 格：开 1 支", r.unitsUsed, 1)
    eqi("新支用掉 1 格：剩余 2 格", r.remainingPartial, 2)
}
do {
    let r = RefillMath.consume(needed: 4, units: 1, capacityPerUnit: 3, partial: 2)
    eqi("已开封 2 + 新支 2：补 4 格", r.filled, 4)
    eqi("已开封 2 + 新支 2：开 1 支", r.unitsUsed, 1)
    eqi("已开封 2 + 新支 2：剩余 1 格", r.remainingPartial, 1)
}

// 4.4 库存不足：只补能补的，绝不假装补过了
do {
    let r = RefillMath.consume(needed: 5, units: 1, capacityPerUnit: 3, partial: 0)
    eqi("库存不足：只补 3 格", r.filled, 3)
    eqi("库存不足：用光 1 支", r.unitsUsed, 1)
    check("库存不足：标记 wasShort", r.wasShort)
}

// 4.5 完全没有库存
do {
    let r = RefillMath.consume(needed: 2, units: 0, capacityPerUnit: 3, partial: 0)
    eqi("零库存：一格都没补", r.filled, 0)
    eqi("零库存：没用任何支", r.unitsUsed, 0)
    check("零库存：wasShort", r.wasShort)
}

// 4.6 替换式：一格一个
do {
    let r = RefillMath.consume(needed: 2, units: 2, capacityPerUnit: 1, partial: 0)
    eqi("替换式：补 2 格", r.filled, 2)
    eqi("替换式：用 2 个", r.unitsUsed, 2)
    eqi("替换式：无开封剩余", r.remainingPartial, 0)
}

// 4.7 不需要补
do {
    let r = RefillMath.consume(needed: 0, units: 3, capacityPerUnit: 3, partial: 1)
    eqi("不需要补：不动库存", r.unitsUsed, 0)
    eqi("不需要补：剩余不变", r.remainingPartial, 1)
    check("不需要补：不标记缺货", !r.wasShort)
}

// 4.8 容量为 0 的脏数据不该导致死循环或崩溃
do {
    let r = RefillMath.consume(needed: 2, units: 2, capacityPerUnit: 0, partial: 0)
    eqi("容量 0 按 1 兜底：补 2 格", r.filled, 2)
    eqi("容量 0 按 1 兜底：用 2 支", r.unitsUsed, 2)
}

print("\n═══ 5. 总容量（两种补充装合并）═══")
eqi("挤入 2 支×3 格", RefillMath.totalCapacity(squeezeUnits: 2, squeezePerUnit: 3, squeezePartial: 0, panUnits: 0), 6)
eqi("挤入 2 支×3 + 开封剩 1", RefillMath.totalCapacity(squeezeUnits: 2, squeezePerUnit: 3, squeezePartial: 1, panUnits: 0), 7)
eqi("挤入 + 替换 3 个", RefillMath.totalCapacity(squeezeUnits: 1, squeezePerUnit: 3, squeezePartial: 0, panUnits: 3), 6)
eqi("全空为 0", RefillMath.totalCapacity(squeezeUnits: 0, squeezePerUnit: 3, squeezePartial: 0, panUnits: 0), 0)

print("\n═══ 6. 端到端场景：一路走完「不缺 → 该补 → 该买」═══")

// 场景：一盒 42 格，群青占 3 格。抽屉里有 1 支挤入式（每支补 3 格）。
do {
    var squeezeUnits = 1
    let squeezePerUnit = 3
    var squeezePartial = 0

    func capacity() -> Int {
        RefillMath.totalCapacity(squeezeUnits: squeezeUnits, squeezePerUnit: squeezePerUnit,
                                 squeezePartial: squeezePartial, panUnits: 0)
    }

    // 第 1 天：3 格都还满 → 够用，别买
    var needed = 0
    eqs("起点：都满 → fine",
        RefillMath.state(needed: needed, capacity: capacity(), isAssigned: true), .fine)
    eqi("起点：没有缺口", RefillMath.shortage(needed: needed, capacity: capacity()), 0)

    // 第 5 天：2 格见底 → 抽屉里有货，直接补，别买
    needed = 2
    eqs("2 格见底 → canRefill（别买）",
        RefillMath.state(needed: needed, capacity: capacity(), isAssigned: true), .canRefill)
    eqi("2 格见底 → 无缺口", RefillMath.shortage(needed: needed, capacity: capacity()), 0)
    eqi("2 格见底 → 建议购买 0 件",
        RefillMath.unitsToBuy(shortage: RefillMath.shortage(needed: needed, capacity: capacity()),
                              capacityPerUnit: squeezePerUnit), 0)

    // 执行补充
    let consumed = RefillMath.consume(needed: needed, units: squeezeUnits,
                                      capacityPerUnit: squeezePerUnit, partial: squeezePartial)
    eqi("补充：补上 2 格", consumed.filled, 2)
    eqi("补充：开 1 支", consumed.unitsUsed, 1)
    eqi("补充：开封那支还剩 1 格", consumed.remainingPartial, 1)
    squeezeUnits -= consumed.unitsUsed
    squeezePartial = consumed.remainingPartial
    eqi("补充后：容量还剩 1 格", capacity(), 1)

    // 第 10 天：又有 2 格见底 → 只剩 1 格容量，缺 1 格，该买
    needed = 2
    let gap = RefillMath.shortage(needed: needed, capacity: capacity())
    eqi("再次见底：缺 1 格", gap, 1)
    eqs("再次见底 → mustBuy",
        RefillMath.state(needed: needed, capacity: capacity(), isAssigned: true), .mustBuy)
    eqi("建议买 1 支（不是 2 支）",
        RefillMath.unitsToBuy(shortage: gap, capacityPerUnit: squeezePerUnit), 1)

    // 买 1 支之后
    squeezeUnits += 1
    eqi("买 1 支后：容量 = 开封剩 1 + 新支 3 = 4", capacity(), 4)
    eqs("买完之后 → 够用，不再提示买",
        RefillMath.state(needed: needed, capacity: capacity(), isAssigned: true), .canRefill)
    eqi("买完之后：缺口归零", RefillMath.shortage(needed: needed, capacity: capacity()), 0)

    // 防过多：如果一口气买了 4 支
    var hoarded = squeezeUnits + 3
    let hoardedCapacity = RefillMath.totalCapacity(squeezeUnits: hoarded, squeezePerUnit: squeezePerUnit,
                                                   squeezePartial: squeezePartial, panUnits: 0)
    eqs("囤到 13 格容量、无缺口 → 提示过多，别买",
        RefillMath.state(needed: 0, capacity: hoardedCapacity, isAssigned: true), .overstocked)
    hoarded = 0  // 避免未使用告警
    _ = hoarded
}

print("\n═══ 7. 文案 ═══")
check("有缺口时文案提到差多少",
      RefillMath.shortfallExplanation(needed: 5, capacity: 2).contains("差 3 格"),
      RefillMath.shortfallExplanation(needed: 5, capacity: 2))
check("够用时文案说不用买",
      RefillMath.shortfallExplanation(needed: 2, capacity: 5).contains("不用买"))
check("不需要补时文案直说不缺",
      RefillMath.shortfallExplanation(needed: 0, capacity: 5).contains("没有格子需要补"))

print("\n═══════════════════════════════════════════════════════")
print("通过 \(passed)  失败 \(failed)")
exit(failed == 0 ? 0 : 1)
