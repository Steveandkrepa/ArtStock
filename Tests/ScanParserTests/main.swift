//
//  PaintScanParser 回归测试
//
//  与干燥模型、补充装算术同样的思路：解析器只依赖 Foundation，
//  可以脱离 iOS SDK 直接在 macOS 上跑。
//
//  这里守住的是一堆**很容易写错、又很难靠肉眼发现**的边界：
//  嵌套 JSON 的摊平、中文键的宽松匹配、GS1 括号写法的切分、
//  零售条码不被误判成 GS1、中文色名到色值的映射。
//
//  用法：./scripts/run-scan-tests.sh
//

import Foundation

var passed = 0
var failed = 0

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { passed += 1; print("  ✅ \(label)") }
    else { failed += 1; print("  ❌ \(label)\(detail().isEmpty ? "" : "  → \(detail())")") }
}
func eq<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    check(label, actual == expected, "actual=\(actual) expected=\(expected)")
}

// ═══════════════════════════════════════════════════════════
print("═══ 1. JSON 载荷 ═══")
do {
    let p = ##"{"code":"6901234567892","name":"群青","brand":"温莎牛顿","series":"艺术家级","hex":"#2E5BFF"}"##
    let d = PaintScanParser.parse(payload: p, symbologyRaw: "org.iso.QRCode")
    eq("来源", d.source, .json)
    eq("色号", d.code, "6901234567892")
    eq("颜色名", d.name, "群青")
    eq("品牌", d.brand, "温莎牛顿")
    eq("系列", d.series, "艺术家级")
    eq("色值", d.hex, "#2E5BFF")
    check("识别到颜色", d.hasColor)
    check("不是零售条码", !d.isRetailCode)
}
do {
    let p = ##"{"paint":{"itemcode":"A-2","colorname":"镉红","colorhex":"#D6303A"}}"##
    let d = PaintScanParser.parse(payload: p)
    eq("嵌套 JSON 色号", d.code, "A-2")
    eq("嵌套 JSON 颜色名", d.name, "镉红")
    eq("嵌套 JSON 色值", d.hex, "#D6303A")
}
do {
    // 数值型色号
    let p = ##"{"code":12345678,"name":"测试色"}"##
    let d = PaintScanParser.parse(payload: p)
    eq("数值型色号被转成字符串", d.code, "12345678")
}

print("\n═══ 2. 键值文本（中文键 + 全角冒号 + 分号）═══")
do {
    let p = "编号=PH-001；颜色名：酞菁蓝\n品牌=马利\n系列=学生级\n色值=#1F6B3A"
    let d = PaintScanParser.parse(payload: p)
    eq("来源", d.source, .keyValue)
    eq("编号", d.code, "PH-001")
    eq("颜色名", d.name, "酞菁蓝")
    eq("品牌", d.brand, "马利")
    eq("系列", d.series, "学生级")
    eq("色值", d.hex, "#1F6B3A")
}

print("\n═══ 3. URL 载荷 ═══")
do {
    let d = PaintScanParser.parse(payload: "https://art.example.com/c/PC-77?name=%E7%BE%A4%E9%9D%92&hex=%232E5BFF")
    eq("来源", d.source, .url)
    eq("路径末段取色号", d.code, "PC-77")
    eq("query 颜色名（百分号解码）", d.name, "群青")
    eq("query 色值（%23 解码为 #）", d.hex, "#2E5BFF")
}
do {
    let d = PaintScanParser.parse(payload: "artstock://color/whatever?code=PC-9")
    eq("显式 code 参数优先", d.code, "PC-9")
}

print("\n═══ 4. GS1 条码 ═══")
do {
    // 括号写法：曾经因为按 ")" 切分而完全解析失败，是重点回归用例
    let d = PaintScanParser.parse(payload: "(01)06901234567892(10)LOT77")
    eq("来源", d.source, .gs1)
    eq("GTIN → 色号", d.code, "06901234567892")
}
do {
    let d = PaintScanParser.parse(payload: "0106901234567892\u{1D}10LOT88")
    eq("紧凑写法色号", d.code, "06901234567892")
}
do {
    let d = PaintScanParser.parse(payload: "0106901234567892")
    eq("纯数字 16 位", d.code, "06901234567892")
}

print("\n═══ 5. 零售条码与纯文本（**不该被误判成 GS1**）═══")
for plain in ["6901234567892", "ART-0001", "ART-01", "X01Y", "PH-001"] {
    let d = PaintScanParser.parse(payload: plain, symbologyRaw: "org.gs1.EAN-13")
    eq("零售码来源 [\(plain)]", d.source, .plain)
    eq("零售码原文保留 [\(plain)]", d.code, plain)
    check("标记为零售条码 [\(plain)]", d.isRetailCode)
    check("没有颜色，需手工选 [\(plain)]", !d.hasColor)
}
do {
    let d = PaintScanParser.parse(payload: "  pc-77  ")
    eq("纯文本去空白并大写", d.code, "PC-77")
    eq("来源", d.source, .plain)
}

print("\n═══ 6. 中文色名 → 色值 ═══")
do {
    let d = PaintScanParser.parse(payload: ##"{"code":"X1","name":"群青"}"##)
    eq("色名转色值", d.hex, "#2E5BFF")
}
do {
    let d = PaintScanParser.parse(payload: ##"{"code":"X1","colorname":"深红"}"##)
    check("深红优先于红（长名先匹配）", d.hex == "#8B1A1A", "actual=\(d.hex ?? "nil")")
}
do {
    let d = PaintScanParser.parse(payload: ##"{"code":"X1","name":"钛白"}"##)
    check("钛白有映射", d.hex != nil, "actual=nil")
}

print("\n═══ 7. 色值规范化 ═══")
do {
    let d = PaintScanParser.parse(payload: ##"{"code":"X1","hex":"#f00"}"##)
    eq("三位缩写展开", d.hex, "#FF0000")
}
do {
    let d = PaintScanParser.parse(payload: ##"{"code":"X1","hex":"2e5bff"}"##)
    eq("无 # 前缀也认", d.hex, "#2E5BFF")
}
do {
    let d = PaintScanParser.parse(payload: ##"{"code":"X1","hex":"不是颜色"}"##)
    check("无效色值给出警告", d.warnings.contains { $0.contains("无法识别") }, "warnings=\(d.warnings)")
}

print("\n═══ 8. 自家标签与空输入 ═══")
do {
    let p = ##"{"generator":"ArtStock","code":"PC-1","name":"测试"}"##
    let d = PaintScanParser.parse(payload: p, symbologyRaw: "org.iso.QRCode")
    check("识别为自家标签", d.isOwnLabel)
}
do {
    let d = PaintScanParser.parse(payload: "   ")
    eq("空白输入色号为空", d.code, "")
    check("空白输入有警告", !d.warnings.isEmpty)
}

print("\n═══ 9. 质量描述（给用户看的预期管理）═══")
do {
    let rich = PaintScanParser.parse(payload: ##"{"code":"X1","name":"群青","hex":"#2E5BFF"}"##)
    check("字段齐全时说可直接入库",
          rich.qualitySummary.contains("直接入库"), rich.qualitySummary)
}
do {
    let retail = PaintScanParser.parse(payload: "6901234567892", symbologyRaw: "org.gs1.EAN-13")
    check("零售条码时明确说颜色要手选",
          retail.qualitySummary.contains("颜色请手动选"), retail.qualitySummary)
}
do {
    let partial = PaintScanParser.parse(payload: ##"{"code":"X1","brand":"马利"}"##)
    check("只有部分字段时说明要补颜色",
          partial.qualitySummary.contains("需要你选"), partial.qualitySummary)
}

print("\n═══ 10. 符号类型展示 ═══")
eq("QR 码", ScanSymbology.displayName(forRawValue: "org.iso.QRCode"), "QR 码")
eq("EAN-13", ScanSymbology.displayName(forRawValue: "org.gs1.EAN-13"), "EAN-13 条码")
check("gs1 前缀算零售条码", ScanSymbology.isRetailBarcode("org.gs1.EAN-13"))
check("QR 不算零售条码", !ScanSymbology.isRetailBarcode("org.iso.QRCode"))
eq("未知类型不崩", ScanSymbology.displayName(forRawValue: ""), "未知")
check("所有来源都有展示名与说明",
      PayloadSource.allCases.allSatisfy { !$0.displayName.isEmpty && !$0.automationHint.isEmpty })

print("\n═══ 11. 共用条码（真实反馈的那条）═══")
// 「颜料本身不同颜色的条形码都是一样的，不是每个颜色一个条形码」
// 条码不能当颜色身份，必须按"可能共用"处理，否则第二支颜料永远进不来。
do {
    let ean = PaintScanParser.parse(payload: "6901234567892", symbologyRaw: "org.gs1.EAN-13")
    check("一维零售条码标记为可能共用", ean.payloadMayBeShared)
    check("并明确提示条码不能当身份",
          ean.warnings.contains { $0.contains("共用") }, ean.warnings.joined(separator: " | "))
    check("按名字生成的色号带 NAME- 前缀",
          ean.nameBasedCode("群青") == "NAME-群青", ean.nameBasedCode("群青"))
    check("名字为空时退回原编号", ean.nameBasedCode("  ") == ean.code, ean.nameBasedCode("  "))
}
do {
    let gs1 = PaintScanParser.parse(payload: "(01)06901234567892(21)A1", symbologyRaw: "org.gs1.EAN-13")
    check("GS1 也标记为可能共用", gs1.payloadMayBeShared)
}
do {
    // 品牌公众号二维码：同一个品牌所有颜色印的是同一张
    let wechat = PaintScanParser.parse(payload: "https://mp.weixin.qq.com/s/AbCdEf", symbologyRaw: "org.iso.QRCode")
    check("公众号链接被识破", wechat.payloadMayBeShared)
    check("并给出改用认字的建议",
          wechat.warnings.contains { $0.contains("认字") }, wechat.warnings.joined(separator: " | "))
}
do {
    let homepage = PaintScanParser.parse(payload: "https://www.maries.com", symbologyRaw: "org.iso.QRCode")
    check("只有根路径的官网码也算品牌级", homepage.payloadMayBeShared)
}
do {
    // 产品级二维码：路径/参数里带型号 → 不该被误判
    let product = PaintScanParser.parse(payload: "https://shop.example.com/p?sku=PY35-12", symbologyRaw: "org.iso.QRCode")
    check("带 SKU 的产品码不误判", !product.payloadMayBeShared)
}
do {
    // 纯文本二维码、一个数字都没有 → 不可能是 SKU
    let slogan = PaintScanParser.parse(payload: "马利画材 艺无止境", symbologyRaw: "org.iso.QRCode")
    check("没有数字的二维码算品牌级", slogan.payloadMayBeShared)
}
do {
    // 本应用自己的标签必须保持产品级
    let own = PaintScanParser.parse(payload: ##"{"generator":"artstock","code":"PY35-12","name":"中黄"}"##, symbologyRaw: "org.iso.QRCode")
    check("自家标签不算共用", !own.payloadMayBeShared)
    check("自家标签能解析出颜色名", own.name == "中黄", own.name ?? "nil")
}
check("公众号域名判定：微信", ScanSymbology.isBrandMarketingURL("https://mp.weixin.qq.com/s/x"))
check("公众号域名判定：淘宝", ScanSymbology.isBrandMarketingURL("https://item.taobao.com/i.htm?id=1"))
check("公众号域名判定：非营销域名不误判", !ScanSymbology.isBrandMarketingURL("https://shop.example.com/p/12"))
check("公众号域名判定：非 http 不误判", !ScanSymbology.isBrandMarketingURL("artstock://color?code=X"))

print("\n═══════════════════════════════════════════════════════")
print("通过 \(passed)  失败 \(failed)")
exit(failed == 0 ? 0 : 1)
