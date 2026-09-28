//
//  DryingModel 回归测试
//
//  与 ParserTests 同样的思路：干燥模型是这个功能里**唯一能被真正验证**的部分，
//  它刻意只依赖 Foundation，所以可以在 macOS 上直接编译运行。
//
//  用法：./scripts/run-model-tests.sh
//

import Foundation

var passed = 0
var failed = 0

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { passed += 1; print("  ✅ \(label)") }
    else { failed += 1; print("  ❌ \(label)\(detail().isEmpty ? "" : "  → \(detail())")") }
}
func eq(_ label: String, _ a: Double, _ b: Double, tol: Double = 0.01) {
    check(label, abs(a - b) <= tol, "actual=\(a) expected=\(b)")
}
func eqi(_ label: String, _ a: Int, _ b: Int) {
    check(label, a == b, "actual=\(a) expected=\(b)")
}

// ═══════════════════════════════════════════════════════════
print("═══ 1. Magnus 公式（对已知物理值）═══")

// 冰点：es(0℃) ≈ 0.611 kPa
eq("es(0℃) ≈ 0.611 kPa", DryingModel.saturationVaporPressure(temperatureC: 0), 0.611, tol: 0.005)
// 常温：es(20℃) ≈ 2.339 kPa
eq("es(20℃) ≈ 2.339 kPa", DryingModel.saturationVaporPressure(temperatureC: 20), 2.339, tol: 0.01)
// 沸点：es(100℃) 应当接近 1 个标准大气压 101.325 kPa
// ——这是对公式最强的正确性检验：如果系数写错，这一条会大幅偏离。
let es100 = DryingModel.saturationVaporPressure(temperatureC: 100)
check("es(100℃) ≈ 101.3 kPa（沸点校验）", abs(es100 - 101.325) < 2.0, "actual=\(es100)")
// 单调性
check("es 随温度单调递增",
      DryingModel.saturationVaporPressure(temperatureC: 5)
      < DryingModel.saturationVaporPressure(temperatureC: 25))

print("\n═══ 2. VPD 水汽压差 ═══")

// RH = 100% 时理论 VPD = 0，被下限钳到 minimumVPD
eq("RH=100% 时 VPD 触及下限",
   DryingModel.vaporPressureDeficit(temperatureC: 22, relativeHumidity: 100),
   DryingModel.minimumVPD)
// RH = 50%、22℃ 时 VPD = es(22) * 0.5
let es22 = DryingModel.saturationVaporPressure(temperatureC: 22)
eq("RH=50% / 22℃ 时 VPD = es/2",
   DryingModel.vaporPressureDeficit(temperatureC: 22, relativeHumidity: 50),
   es22 / 2, tol: 0.01)
// RH = 0 被钳到 minimumHumidity(5%)，不是 0
eq("RH=0 被钳到 5%",
   DryingModel.vaporPressureDeficit(temperatureC: 20, relativeHumidity: 0),
   DryingModel.vaporPressureDeficit(temperatureC: 20, relativeHumidity: DryingModel.minimumHumidity))
// 单调性：湿度越高 VPD 越低；温度越高 VPD 越高
check("VPD 随湿度升高而降低",
      DryingModel.vaporPressureDeficit(temperatureC: 22, relativeHumidity: 30)
      > DryingModel.vaporPressureDeficit(temperatureC: 22, relativeHumidity: 80))
check("VPD 随温度升高而升高",
      DryingModel.vaporPressureDeficit(temperatureC: 30, relativeHumidity: 50)
      > DryingModel.vaporPressureDeficit(temperatureC: 15, relativeHumidity: 50))
// 上限护栏
check("VPD 不会超过上限",
      DryingModel.vaporPressureDeficit(temperatureC: 60, relativeHumidity: 5) <= DryingModel.maximumVPD)

print("\n═══ 3. 预测基本性质 ═══")

let base = DryingInput(temperatureC: 22, relativeHumidity: 50,
                       paintSystem: .oil, closure: .open, startedAt: Date())
let f = DryingModel.forecast(base)

check("结皮时长为正", f.skinningHours > 0, "\(f.skinningHours)")
eq("结皮时长 = K / VPD", f.skinningHours, f.effectiveCalibration / f.vaporPressureDeficit, tol: 0.001)
check("补水时刻早于结皮时刻", f.remistDeadline < base.startedAt.addingTimeInterval(f.skinningHours * 3600))
check("预警时刻早于补水时刻", f.preWarnAt < f.remistDeadline)
check("默认未标定标记正确", f.isCalibrated == false)
check("有说明文案", !f.notes.isEmpty)

// 密闭容器应当显著延长
let sealed = DryingModel.forecast(DryingInput(
    temperatureC: 22, relativeHumidity: 50, paintSystem: .oil, closure: .sealedBox, startedAt: Date()))
check("密闭调色盒比开放放置更耐久",
      sealed.skinningHours > f.skinningHours,
      "sealed=\(sealed.skinningHours) open=\(f.skinningHours)")
eq("倍数关系正确", sealed.skinningHours / f.skinningHours, PaletteClosure.sealedBox.retentionFactor, tol: 0.01)

// 干燥环境应当显著缩短
let dry = DryingModel.forecast(DryingInput(
    temperatureC: 30, relativeHumidity: 15, paintSystem: .oil, closure: .open, startedAt: Date()))
check("干燥高温环境更快干", dry.skinningHours < f.skinningHours,
      "dry=\(dry.skinningHours) base=\(f.skinningHours)")

// 不同颜料体系的默认差异
let oil = DryingModel.forecast(DryingInput(temperatureC: 22, relativeHumidity: 50,
                                           paintSystem: .oil, closure: .open, startedAt: Date()))
let wc = DryingModel.forecast(DryingInput(temperatureC: 22, relativeHumidity: 50,
                                          paintSystem: .watercolor, closure: .open, startedAt: Date()))
check("油画比水彩耐久得多", oil.skinningHours > wc.skinningHours * 3,
      "oil=\(oil.skinningHours) wc=\(wc.skinningHours)")

print("\n═══ 4. 喷雾下数 ═══")

let withSpray = DryingModel.forecast(DryingInput(
    temperatureC: 22, relativeHumidity: 50, paintSystem: .oil, closure: .open,
    minutesPerSpray: 30, startedAt: Date()))
check("标定后有喷雾下数", withSpray.spraysPerRemist > 0, "\(withSpray.spraysPerRemist)")
eqi("未标定时不给下数", f.spraysPerRemist, 0)
eqi("直接算：60 分钟 / 15 分钟 = 4 下", DryingModel.sprays(forIntervalMinutes: 60, minutesPerSpray: 15), 4)
eqi("向上取整：61 分钟 / 15 分钟 = 5 下", DryingModel.sprays(forIntervalMinutes: 61, minutesPerSpray: 15), 5)
eqi("下数有上限（不超过 20）", DryingModel.sprays(forIntervalMinutes: 100000, minutesPerSpray: 1), 20)
eqi("未标定维持时长时返回 0", DryingModel.sprays(forIntervalMinutes: 60, minutesPerSpray: 0), 0)

print("\n═══ 5. 实测校准：**回环一致性**（最关键的一组）═══")

// 场景：用户在 22℃ / 50% 湿度下开放放置油画颜料，
//       实测 10 小时后需要补水。校准后重新预测，应当复现"10 小时后补水"。
let observedHours = 10.0
let temp = 22.0
let rh = 50.0
let closure = PaletteClosure.open

guard let k = DryingModel.calibrate(observedHours: observedHours, temperatureC: temp,
                                    relativeHumidity: rh, closure: closure) else {
    print("  ❌ calibrate 返回 nil，后续回环测试无法进行")
    failed += 1
    print("\n通过 \(passed)  失败 \(failed)")
    exit(1)
}
print("  校准得到 K = \(String(format: "%.2f", k)) kPa·h")

let recalibrated = DryingModel.forecast(DryingInput(
    temperatureC: temp, relativeHumidity: rh, paintSystem: .oil, closure: closure,
    calibrationOverride: k, startedAt: Date()))

check("标记为已校准", recalibrated.isCalibrated)

// ★ 核心断言：预测的补水时刻必须复现用户实测的 10 小时。
//   如果 calibrate() 忘了除以 remistFraction，这里会得到 5 小时 —— 差一倍。
let predictedRemistHours = recalibrated.remistDeadline.timeIntervalSince(recalibrated.startedAt) / 3600
eq("★ 回环：校准后预测的补水时刻 = 实测的 10 小时", predictedRemistHours, observedHours, tol: 0.02)

// 换容器应当按倍数关系缩放（而不是重复计入）
let sealedCalibrated = DryingModel.forecast(DryingInput(
    temperatureC: temp, relativeHumidity: rh, paintSystem: .oil, closure: .sealedBox,
    calibrationOverride: k, startedAt: Date()))
let sealedHours = sealedCalibrated.remistDeadline.timeIntervalSince(sealedCalibrated.startedAt) / 3600
eq("换密闭盒后按倍数延长", sealedHours, observedHours * PaletteClosure.sealedBox.retentionFactor, tol: 0.1)

// 校准的合理性护栏
check("拒绝时长为 0 的校准", DryingModel.calibrate(observedHours: 0, temperatureC: 22,
                                                   relativeHumidity: 50, closure: .open) == nil)
check("拒绝负时长", DryingModel.calibrate(observedHours: -3, temperatureC: 22,
                                          relativeHumidity: 50, closure: .open) == nil)
check("拒绝离谱的时长（超过 30 天）", DryingModel.calibrate(observedHours: 24 * 40, temperatureC: 22,
                                                            relativeHumidity: 50, closure: .open) == nil)
check("极短时长会因 K 越界被拒", DryingModel.calibrate(observedHours: 0.06, temperatureC: 45,
                                                       relativeHumidity: 5, closure: .open) == nil)

print("\n═══ 6. 枚举与文案完整性 ═══")
check("所有颜料体系有显示名/图标/说明",
      PaintSystem.allCases.allSatisfy { !$0.displayName.isEmpty && !$0.symbolName.isEmpty && !$0.calibrationNote.isEmpty })
check("所有颜料体系的默认常数 > 0",
      PaintSystem.allCases.allSatisfy { $0.defaultCalibration > 0 })
check("所有封闭方式有显示名/图标/说明",
      PaletteClosure.allCases.allSatisfy { !$0.displayName.isEmpty && !$0.symbolName.isEmpty && !$0.note.isEmpty })
check("封闭方式倍数都 >= 1",
      PaletteClosure.allCases.allSatisfy { $0.retentionFactor >= 1.0 })
check("开放放置是基线倍数 1.0", PaletteClosure.open.retentionFactor == 1.0)

print("\n═══ 6.5 水粉的默认值要贴近真实体感 ═══")

// 用户实测反馈："最多 1 小时就需要喷水"（开放盒、室温）。
// 早期版本水粉被并进水彩且 K=8、默认容器又是密闭盒，
// 叠起来高估了 8 倍以上。这一节守住修正后的默认值。
do {
    let f = DryingModel.forecast(DryingInput(
        temperatureC: 22, relativeHumidity: 50,
        paintSystem: .gouache, closure: .open, startedAt: Date()))
    let remistHours = f.remistDeadline.timeIntervalSince(f.startedAt) / 3600
    check("水粉开放盒 22℃/50% → 建议补水在 0.5–1.5 小时之间",
          remistHours > 0.5 && remistHours < 1.5,
          "actual=\(String(format: "%.2f", remistHours)) h")
}

// 所有体系的默认补水时刻都不该超过一天 —— 超过说明起点值又飘了
for system in PaintSystem.allCases {
    let f = DryingModel.forecast(DryingInput(
        temperatureC: 22, relativeHumidity: 50,
        paintSystem: system, closure: .open, startedAt: Date()))
    let hours = f.remistDeadline.timeIntervalSince(f.startedAt) / 3600
    check("\(system.displayName) 开放放置的默认补水 ≤ 24h（实际 \(String(format: "%.1f", hours))h）",
          hours <= 24)
}

// 水粉必须是所有体系里最快干的
do {
    let g = DryingModel.forecast(DryingInput(temperatureC: 22, relativeHumidity: 50,
                                             paintSystem: .gouache, closure: .open, startedAt: Date()))
    for other in PaintSystem.allCases where other != .gouache {
        let o = DryingModel.forecast(DryingInput(temperatureC: 22, relativeHumidity: 50,
                                                 paintSystem: other, closure: .open, startedAt: Date()))
        check("水粉比\(other.displayName)更快到补水点",
              g.remistDeadline < o.remistDeadline)
    }
}

print("\n═══ 7. 边界与稳健性 ═══")

// 极端湿度不能产生 NaN / 无穷
for (t, r) in [(-20.0, 100.0), (0.0, 0.0), (50.0, 5.0), (22.0, 99.9), (60.0, 0.0)] {
    let fx = DryingModel.forecast(DryingInput(temperatureC: t, relativeHumidity: r,
                                              paintSystem: .other, closure: .open, startedAt: Date()))
    check("极端输入 (\(t)℃ / \(r)%) 结果有限且为正",
          fx.skinningHours.isFinite && fx.skinningHours > 0,
          "\(fx.skinningHours)")
}
// 时间点必须严格有序
for (t, r) in [(5.0, 90.0), (35.0, 20.0), (22.0, 50.0)] {
    let fx = DryingModel.forecast(DryingInput(temperatureC: t, relativeHumidity: r,
                                              paintSystem: .acrylic, closure: .wetPad, startedAt: Date()))
    check("时刻有序 (\(t)℃/\(r)%): preWarn < deadline < skinning",
          fx.preWarnAt < fx.remistDeadline
          && fx.remistDeadline < fx.startedAt.addingTimeInterval(fx.skinningHours * 3600 + 1))
}
// 补水间隔为正
check("补水间隔为正且不小于 10 分钟",
      DryingModel.forecast(DryingInput(temperatureC: 40, relativeHumidity: 5,
                                       paintSystem: .watercolor, closure: .open,
                                       startedAt: Date())).remistIntervalMinutes >= 10)

print("\n═══════════════════════════════════════════════════════")
print("通过 \(passed)  失败 \(failed)")
exit(failed == 0 ? 0 : 1)
