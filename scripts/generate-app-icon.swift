//
//  generate-app-icon.swift
//  ArtAssist — 美术生的工具箱
//
//  程序化生成 1024×1024 的 App 图标。
//
//  ── 这一版的设计（ArtAssist）─────────────────────────────────
//  意象：**一整盒颜料，看得见余量。**
//
//  这是整个 App 的核心 —— 不是"画画"，是"知道还剩多少"。
//  所以图标不是调色盘、不是画笔，而是一盒**正面朝上的颜料格**，
//  其中两格的颜料明显矮下去（快用完了），一眼能读出"余量"这层意思。
//
//  色值取自 `PresetColors.standard42` 里实测的厂家色卡值，
//  所以图标上的颜色和你 App 里看到的、你盒子里的是同一批。
//
//  ── 为什么不烘焙圆角 ─────────────────────────────────────────
//  iOS 自己会给图标套 squircle 蒙版。自己再切一次圆角，结果是
//  蒙版套蒙版、四角发虚。所以这里出的是**满幅方图**。
//
//  ── 为什么用 noneSkipLast ────────────────────────────────────
//  App Store（以及部分校验）会拒收带 alpha 通道的 1024 图标。
//  本图满幅不透明，直接用不透明 RGBX 渲染，顺带省约 25% 体积。
//

import CoreGraphics
import Foundation
import ImageIO

let size = 1024
let side = CGFloat(size)

let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("无法创建绘图上下文") }

ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

// MARK: - 小工具

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

extension CGColor {
    /// 往黑或白方向混一点，用来做"湿颜料"的上下渐变。
    func shade(_ amount: CGFloat) -> CGColor {
        guard let c = components, c.count >= 3 else { return self }
        let target: CGFloat = amount < 0 ? 0 : 1
        let t = abs(amount)
        let alpha = c.count >= 4 ? c[3] : 1
        return CGColor(srgbRed: c[0] + (target - c[0]) * t,
                       green: c[1] + (target - c[1]) * t,
                       blue: c[2] + (target - c[2]) * t,
                       alpha: alpha)
    }
}

func roundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// 圆角矩形的纵向渐变填充。CGContext 没有直接 API，用 clip + 线性渐变。
func fillVerticalGradient(_ path: CGPath, top: CGColor, bottom: CGColor, in context: CGContext) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray,
                              locations: [0, 1])!
    let box = path.boundingBox
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: box.midX, y: box.maxY),
                               end: CGPoint(x: box.midX, y: box.minY),
                               options: [])
    context.restoreGState()
}

// MARK: - 1. 背景：靛蓝 → 紫罗兰，加一道左上高光

let bgColors = [rgb(0x1A1436), rgb(0x33206E), rgb(0x5B2FA8), rgb(0x7E3FD0)] as CFArray
let bg = CGGradient(colorsSpace: space, colors: bgColors, locations: [0, 0.42, 0.78, 1])!
ctx.drawLinearGradient(bg,
                       start: CGPoint(x: side * 0.15, y: side),
                       end: CGPoint(x: side * 0.9, y: 0),
                       options: [])

// 左上角的柔光：让整块图标有"玻璃被照亮"的感觉
let glow = CGGradient(colorsSpace: space,
                      colors: [rgb(0xFFFFFF, 0.17), rgb(0xFFFFFF, 0.0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow,
                       startCenter: CGPoint(x: side * 0.24, y: side * 0.82), startRadius: 0,
                       endCenter: CGPoint(x: side * 0.24, y: side * 0.82), endRadius: side * 0.62,
                       options: [])

// 右下角的暗角，把视线压回中间
let vignette = CGGradient(colorsSpace: space,
                          colors: [rgb(0x000000, 0.0), rgb(0x0B0620, 0.42)] as CFArray,
                          locations: [0.45, 1])!
ctx.drawRadialGradient(vignette,
                       startCenter: CGPoint(x: side * 0.5, y: side * 0.5), startRadius: 0,
                       endCenter: CGPoint(x: side * 0.5, y: side * 0.5), endRadius: side * 0.78,
                       options: [])

// MARK: - 2. 颜料盒本体（玻璃质感的圆角面板）

let panelInset = side * 0.155
let panelRect = CGRect(x: panelInset, y: panelInset,
                       width: side - panelInset * 2, height: side - panelInset * 2)
let panelRadius = side * 0.115
let panelPath = roundedPath(panelRect, radius: panelRadius)

// 投影：让盒子从背景上"浮"起来
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.022),
              blur: side * 0.05,
              color: rgb(0x0A0418, 0.55))
ctx.addPath(panelPath)
ctx.setFillColor(rgb(0xF2F0FF, 0.10))
ctx.fillPath()
ctx.restoreGState()

// 面板自身的微渐变（上亮下暗）+ 一圈亮边
fillVerticalGradient(panelPath,
                     top: rgb(0xFFFFFF, 0.20),
                     bottom: rgb(0xFFFFFF, 0.07),
                     in: ctx)

ctx.saveGState()
ctx.addPath(panelPath)
ctx.setStrokeColor(rgb(0xFFFFFF, 0.30))
ctx.setLineWidth(side * 0.0065)
ctx.strokePath()
ctx.restoreGState()

// MARK: - 3. 六格颜料

/// **3 列 × 3 行 = 9 格**，方格而不是长条 —— 更接近真实颜料盒的样子。
///
/// （试过 3×2，格子被拉成瘦长条，看着像药盒不像颜料盒。）
///
/// 第二个参数是"还剩多少"：1.0 = 满格。
/// 图标上特意放了三个不满的格子，且深浅各不相同 ——
/// "一眼看出哪几格该补"就是整个 App 想说的那件事。
let wells: [(hex: UInt32, fill: CGFloat)] = [
    (0xD43322, 1.00),   // 朱红
    (0xF5A708, 1.00),   // 中黄
    (0x5AAE33, 0.42),   // 淡绿 —— 快见底
    (0x1AA7CA, 1.00),   // 湖蓝
    (0xBB1A5C, 0.64),   // 玫瑰红 —— 用掉一半多
    (0x232E62, 1.00),   // 群青
    (0xFE9E3C, 1.00),   // 桔黄
    (0xB03A6E, 0.30),   // 紫红 —— 只剩一点点
    (0xFEFEFE, 1.00),   // 钛白
]

let columns = 3
let rows = 3
let outerPad = panelRect.width * 0.095
let gap = panelRect.width * 0.042
let gridOrigin = CGPoint(x: panelRect.minX + outerPad, y: panelRect.minY + outerPad)
let cellW = (panelRect.width - outerPad * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns)
let cellH = (panelRect.height - outerPad * 2 - gap * CGFloat(rows - 1)) / CGFloat(rows)
// 圆角比例大一点，格子看起来是"凹陷的圆孔"而不是贴上去的小方块
let wellRadius = min(cellW, cellH) * 0.34

for (index, well) in wells.enumerated() {
    let column = index % columns
    let row = index / columns
    let rect = CGRect(
        x: gridOrigin.x + CGFloat(column) * (cellW + gap),
        // CoreGraphics 原点在左下，但行的视觉顺序是"从上到下"，所以第一行放上面。
        y: gridOrigin.y + CGFloat(rows - 1 - row) * (cellH + gap),
        width: cellW, height: cellH
    )

    let base = rgb(well.hex)
    let slotPath = roundedPath(rect, radius: wellRadius)

    // ① 格底的凹槽：比颜料深
    ctx.saveGState()
    ctx.addPath(slotPath)
    ctx.clip()
    fillVerticalGradient(slotPath,
                         top: base.shade(-0.62),
                         bottom: base.shade(-0.44),
                         in: ctx)
    ctx.restoreGState()

    // ② 颜料：从底部往上占 fill 比例，液面用一条弧线
    let paintHeight = rect.height * well.fill
    let paintRect = CGRect(x: rect.minX, y: rect.minY,
                           width: rect.width, height: paintHeight)
    let meniscus = rect.height * 0.055

    let paintPath = CGMutablePath()
    paintPath.move(to: CGPoint(x: paintRect.minX, y: paintRect.minY))
    paintPath.addLine(to: CGPoint(x: paintRect.maxX, y: paintRect.minY))
    paintPath.addLine(to: CGPoint(x: paintRect.maxX, y: paintRect.maxY - meniscus))
    // 液面：两边高、中间略低（颜料在格子里的自然表面）
    paintPath.addQuadCurve(
        to: CGPoint(x: paintRect.minX, y: paintRect.maxY - meniscus),
        control: CGPoint(x: paintRect.midX, y: paintRect.maxY + meniscus * 0.5)
    )
    paintPath.closeSubpath()

    ctx.saveGState()
    ctx.addPath(slotPath)
    ctx.clip()
    fillVerticalGradient(paintPath,
                         top: base.shade(0.18),
                         bottom: base.shade(-0.16),
                         in: ctx)
    // 液面高光：一条细白线，颜料看起来是湿的
    ctx.addPath(paintPath)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.30))
    ctx.setLineWidth(side * 0.0032)
    ctx.strokePath()
    ctx.restoreGState()

    // ③ 格子的内阴影 + 上缘亮边
    ctx.saveGState()
    ctx.addPath(slotPath)
    ctx.setStrokeColor(rgb(0x000000, 0.28))
    ctx.setLineWidth(side * 0.005)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(slotPath)
    ctx.clip()
    ctx.addPath(slotPath)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.30))
    ctx.setLineWidth(side * 0.010)
    ctx.strokePath()
    ctx.restoreGState()

    // ④ 格子顶部的弧形反光
    ctx.saveGState()
    ctx.addPath(slotPath)
    ctx.clip()
    ctx.setFillColor(rgb(0xFFFFFF, 0.09))
    ctx.fillEllipse(in: CGRect(x: rect.minX + rect.width * 0.10,
                              y: rect.maxY - rect.height * 0.30,
                              width: rect.width * 0.80,
                              height: rect.height * 0.17))
    ctx.restoreGState()
}

// MARK: - 4. 面板整体压一层斜向高光（玻璃盖）

ctx.saveGState()
ctx.addPath(panelPath)
ctx.clip()
let sheen = CGGradient(colorsSpace: space,
                       colors: [rgb(0xFFFFFF, 0.13), rgb(0xFFFFFF, 0.0), rgb(0xFFFFFF, 0.05)] as CFArray,
                       locations: [0, 0.55, 1])!
ctx.drawLinearGradient(sheen,
                       start: CGPoint(x: panelRect.minX, y: panelRect.maxY),
                       end: CGPoint(x: panelRect.maxX, y: panelRect.minY),
                       options: [])
ctx.restoreGState()

// MARK: - 5. 输出

guard let image = ctx.makeImage() else { fatalError("无法生成位图") }
let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/artassist-icon/icon-1024.png"
let url = URL(fileURLWithPath: outPath)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
    fatalError("无法创建 PNG 输出")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("无法写入 PNG") }
print("已生成：\(outPath)")
