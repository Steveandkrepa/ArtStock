//
//  ColorGridSampler 回归测试
//
//  取色这件事有两个错法，肉眼都很难发现：
//    · **通道顺序写反**（BGR 当 RGB）→ 整套颜色红蓝颠倒，
//      看起来像"偏色"而不像"写反了"，能一直用下去
//    · **格子划分偏半格** → 采到隔壁颜料或塑料隔断，整体发灰
//
//  相机和真机没法离线测，但这两件事可以用合成图像钉死。
//
//  用法：./scripts/run-sampler-tests.sh
//

import CoreGraphics
import Foundation

var passed = 0
var failed = 0

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { passed += 1; print("  ✅ \(label)") }
    else { failed += 1; print("  ❌ \(label)\(detail().isEmpty ? "" : "  → \(detail())")") }
}

/// 造假图：width×height 的 BGRA 缓冲，颜色由一个闭包按（列, 行）决定。
func makeBuffer(
    width: Int,
    height: Int,
    columns: Int,
    rows: Int,
    colorAt: (Int, Int) -> (r: UInt8, g: UInt8, b: UInt8)
) -> (pixels: [UInt8], bytesPerRow: Int) {
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    for y in 0..<height {
        for x in 0..<width {
            let column = min(columns - 1, x * columns / width)
            let row = min(rows - 1, y * rows / height)
            let color = colorAt(column, row)
            let offset = y * bytesPerRow + x * 4
            pixels[offset] = color.b      // B
            pixels[offset + 1] = color.g  // G
            pixels[offset + 2] = color.r  // R
            pixels[offset + 3] = 255      // A
        }
    }
    return (pixels, bytesPerRow)
}

let fullGrid = CGRect(x: 0, y: 0, width: 1, height: 1)

// ═══ 1. 通道顺序（最容易错、最难看出来的一条）═══
print("═══ 1. BGRA 通道顺序 ═══")
do {
    // 纯红：BGRA 里应该是 B=0 G=0 R=255
    var pixels = [UInt8](repeating: 0, count: 4)
    pixels[0] = 0; pixels[1] = 0; pixels[2] = 255; pixels[3] = 255
    let color = pixels.withUnsafeBufferPointer { buffer in
        ColorGridSampler.averageColor(
            bgra: buffer.baseAddress!, bytesPerRow: 4,
            width: 1, height: 1, rect: fullGrid
        )
    }
    check("纯红读成红，不是蓝", color?.hex == "#FF0000", color?.hex ?? "nil")
    check("红通道确实是 1.0", (color?.r ?? 0) > 0.99, "\(color?.r ?? -1)")
    check("蓝通道是 0", (color?.b ?? 1) < 0.01, "\(color?.b ?? -1)")
}
do {
    // 纯蓝：B=255 R=0
    var pixels = [UInt8](repeating: 0, count: 4)
    pixels[0] = 255; pixels[3] = 255
    let color = pixels.withUnsafeBufferPointer { buffer in
        ColorGridSampler.averageColor(
            bgra: buffer.baseAddress!, bytesPerRow: 4,
            width: 1, height: 1, rect: fullGrid
        )
    }
    check("纯蓝读成蓝，不是红", color?.hex == "#0000FF", color?.hex ?? "nil")
}
do {
    // 一个偏绿的青色：B=200 G=255 R=40 → #28FFC8
    var pixels = [UInt8](repeating: 0, count: 4)
    pixels[0] = 200; pixels[1] = 255; pixels[2] = 40; pixels[3] = 255
    let color = pixels.withUnsafeBufferPointer { buffer in
        ColorGridSampler.averageColor(
            bgra: buffer.baseAddress!, bytesPerRow: 4,
            width: 1, height: 1, rect: fullGrid
        )
    }
    check("三通道各归各位", color?.hex == "#28FFC8", color?.hex ?? "nil")
}
do {
    // 马尔代夫那种"应该是绿的"的色：绝不能读成蓝
    var pixels = [UInt8](repeating: 0, count: 4)
    pixels[0] = 70; pixels[1] = 170; pixels[2] = 60; pixels[3] = 255  // B=70 G=170 R=60
    let color = pixels.withUnsafeBufferPointer { buffer in
        ColorGridSampler.averageColor(
            bgra: buffer.baseAddress!, bytesPerRow: 4,
            width: 1, height: 1, rect: fullGrid
        )
    }
    check("绿就是绿（G 最大）",
          (color?.g ?? 0) > (color?.r ?? 1) && (color?.g ?? 0) > (color?.b ?? 1),
          color?.hex ?? "nil")
}

// ═══ 2. 格子划分 ═══
print("\n═══ 2. 格子划分（7×6）═══")
do {
    let rects = ColorGridSampler.cellRects(grid: fullGrid, rows: 7, columns: 6)
    check("正好 42 个格子", rects.count == 42, "\(rects.count)")
    // 注意：收了边之后 minX 不会是 0，所以不能拿"等于 0"来判左上。
    // 要判的是**顺序**：第 1 格应该同时是 x 最小和 y 最小的那一格。
    check("行优先：第 1 格在最左上（x、y 都是最小）",
          rects.dropFirst().allSatisfy { $0.minX >= rects[0].minX && $0.minY >= rects[0].minY })
    check("第 6 个在第一行最右",
          rects[5].minX > rects[4].minX && abs(rects[5].minY - rects[0].minY) < 1e-9)
    check("第 7 个换到第二行最左", rects[6].minX == rects[0].minX && rects[6].minY > rects[0].minY)
    check("最后一个在右下角", rects[41].maxX < 1.0 && rects[41].maxY < 1.0)
    // 每格宽 = 1/6，收 0.22 后剩 0.56/6
    let expectedWidth = (1.0 / 6.0) * (1 - 0.44)
    check("收边后格宽正确", abs(rects[0].width - expectedWidth) < 1e-9,
          "\(rects[0].width) 期望 \(expectedWidth)")
    check("42 个格子互不重叠",
          zip(rects, rects.dropFirst()).allSatisfy { !$0.intersects($1) })
}
do {
    let rects = ColorGridSampler.cellRects(grid: fullGrid, rows: 0, columns: 6)
    check("行数为 0 返回空数组，不崩", rects.isEmpty)
    let weird = ColorGridSampler.cellRects(grid: fullGrid, rows: 7, columns: 6, inset: 5)
    check("inset 过大会被夹住（不会变成负宽度）",
          weird.allSatisfy { $0.width >= 0 && $0.height >= 0 })
}
do {
    // 格子框只覆盖画面中间一部分（用户在预览上框出来的范围）
    let inner = CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.8)
    let rects = ColorGridSampler.cellRects(grid: inner, rows: 7, columns: 6)
    check("格子框偏移时结果也跟着偏", rects[0].minX > 0.2 && rects[41].maxX < 0.8)
    check("格子框偏移后仍在框内",
          rects.allSatisfy { inner.insetBy(dx: -1e-9, dy: -1e-9).contains($0) })
}

// ═══ 3. 从合成图里采回 42 个颜色 ═══
print("\n═══ 3. 采回一整盒（7×6 各一个颜色）═══")
do {
    // 拆开来写：一行里塞三个字面量算术会让类型检查爆掉（编译器直接报
    // "unable to type-check this expression in reasonable time"）。
    var palette: [(r: UInt8, g: UInt8, b: UInt8)] = []
    for index in 0..<42 {
        let r: Int = 10 + index * 5
        let g: Int = 200 - index * 4
        let b: Int = 30 + index * 3
        palette.append((r: UInt8(r), g: UInt8(g), b: UInt8(b)))
    }
    let image = makeBuffer(width: 600, height: 700, columns: 6, rows: 7) { column, row in
        palette[row * 6 + column]
    }
    let sampled = image.pixels.withUnsafeBufferPointer { buffer in
        ColorGridSampler.sampleGrid(
            bgra: buffer.baseAddress!, bytesPerRow: image.bytesPerRow,
            width: 600, height: 700,
            grid: fullGrid, rows: 7, columns: 6
        )
    }
    var expected: [String] = []
    for entry in palette {
        let r = Double(entry.r) / 255.0
        let g = Double(entry.g) / 255.0
        let b = Double(entry.b) / 255.0
        expected.append(RGBColor(r: r, g: g, b: b).hex)
    }
    let mismatches = zip(sampled, expected).enumerated().compactMap { index, pair -> String? in
        pair.0 == pair.1 ? nil : "第\(index + 1)格 \(pair.0 ?? "nil") 期望 \(pair.1)"
    }
    check("42 格全部采对（行优先顺序也对）", mismatches.isEmpty,
          mismatches.prefix(4).joined(separator: "; "))
    check("没有 nil", sampled.allSatisfy { $0 != nil })
}
do {
    // 相邻格子颜色完全不同 —— 采偏半格就会立刻暴露
    let image = makeBuffer(width: 600, height: 700, columns: 6, rows: 7) { column, row in
        (column + row) % 2 == 0 ? (r: 255, g: 0, b: 0) : (r: 0, g: 0, b: 255)
    }
    let sampled = image.pixels.withUnsafeBufferPointer { buffer in
        ColorGridSampler.sampleGrid(
            bgra: buffer.baseAddress!, bytesPerRow: image.bytesPerRow,
            width: 600, height: 700, grid: fullGrid, rows: 7, columns: 6
        )
    }
    check("棋盘格：第 1 格是红", sampled[0] == "#FF0000", sampled[0] ?? "nil")
    check("棋盘格：第 2 格是蓝", sampled[1] == "#0000FF", sampled[1] ?? "nil")
    check("棋盘格：全部是纯色（没有采到边界混色）",
          sampled.allSatisfy { $0 == "#FF0000" || $0 == "#0000FF" },
          Set(sampled.compactMap { $0 }).sorted().joined(separator: ", "))
}

// ═══ 4. 平均与越界 ═══
print("\n═══ 4. 平均 / 越界 / 异常输入 ═══")
do {
    // 左半黑右半白，整个画面取平均应该是中灰
    let image = makeBuffer(width: 100, height: 10, columns: 2, rows: 1) { column, _ in
        column == 0 ? (r: 0, g: 0, b: 0) : (r: 255, g: 255, b: 255)
    }
    let color = image.pixels.withUnsafeBufferPointer { buffer in
        ColorGridSampler.averageColor(
            bgra: buffer.baseAddress!, bytesPerRow: image.bytesPerRow,
            width: 100, height: 10, rect: fullGrid
        )
    }
    // 正好一半一半
    check("整幅平均 = 中灰", color?.hex == "#808080", color?.hex ?? "nil")
}
do {
    let image = makeBuffer(width: 40, height: 40, columns: 1, rows: 1) { _, _ in (r: 30, g: 60, b: 90) }
    let color = image.pixels.withUnsafeBufferPointer { buffer in
        ColorGridSampler.averageColor(
            bgra: buffer.baseAddress!, bytesPerRow: image.bytesPerRow,
            width: 40, height: 40,
            // 整个区域都在画面外
            rect: CGRect(x: 1.5, y: 1.5, width: 0.2, height: 0.2)
        )
    }
    check("区域完全在画面外返回 nil", color == nil, color?.hex ?? "nil")
}
do {
    let image = makeBuffer(width: 40, height: 40, columns: 1, rows: 1) { _, _ in (r: 30, g: 60, b: 90) }
    let color = image.pixels.withUnsafeBufferPointer { buffer in
        ColorGridSampler.averageColor(
            bgra: buffer.baseAddress!, bytesPerRow: image.bytesPerRow,
            width: 40, height: 40,
            // 一半在里一半在外
            rect: CGRect(x: 0.8, y: 0.8, width: 0.5, height: 0.5)
        )
    }
    check("部分越界会裁剪而不是崩", color?.hex == "#1E3C5A", color?.hex ?? "nil")
}
do {
    var pixel: UInt8 = 128
    let color = withUnsafePointer(to: &pixel) { pointer in
        ColorGridSampler.averageColor(
            bgra: pointer, bytesPerRow: 4, width: 0, height: 0, rect: fullGrid
        )
    }
    check("尺寸为 0 返回 nil 而不是崩", color == nil)
}
do {
    // bytesPerRow 必须用系统给的值 —— 这里故意加 8 字节 padding
    let width = 8, height = 4, padding = 8
    let bytesPerRow = width * 4 + padding
    var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
    for y in 0..<height {
        for x in 0..<width {
            let offset = y * bytesPerRow + x * 4
            pixels[offset] = 0      // B
            pixels[offset + 1] = 0  // G
            pixels[offset + 2] = 255 // R
        }
    }
    let color = pixels.withUnsafeBufferPointer { buffer in
        ColorGridSampler.averageColor(
            bgra: buffer.baseAddress!, bytesPerRow: bytesPerRow,
            width: width, height: height, rect: fullGrid
        )
    }
    check("有行填充（bytesPerRow > width*4）时仍然采对", color?.hex == "#FF0000", color?.hex ?? "nil")
}

// ═══ 5. 画面摆放 ═══
print("\n═══ 5. 预览层摆放（格子线要对齐取样点）═══")
do {
    // 缓冲 4:3，视图 1:1，fill → 铺满，横向裁掉
    let rect = ColorGridSampler.displayRect(
        bufferSize: CGSize(width: 400, height: 300),
        in: CGSize(width: 300, height: 300),
        fill: true
    )
    check("fill：高度铺满", abs(rect.height - 300) < 1e-9, "\(rect.height)")
    check("fill：宽度超出视图（被裁）", rect.width > 300)
    check("fill：水平居中", abs(rect.midX - 150) < 1e-9, "\(rect.midX)")

    // fit → 完整显示，上下留黑
    let fit = ColorGridSampler.displayRect(
        bufferSize: CGSize(width: 400, height: 300),
        in: CGSize(width: 300, height: 300),
        fill: false
    )
    check("fit：宽度铺满", abs(fit.width - 300) < 1e-9, "\(fit.width)")
    check("fit：高度小于视图", fit.height < 300)
    check("fit：垂直居中", abs(fit.midY - 150) < 1e-9, "\(fit.midY)")
}
do {
    let rect = ColorGridSampler.displayRect(
        bufferSize: CGSize(width: 400, height: 300), in: .zero, fill: true
    )
    check("视图尺寸为 0 返回 .zero 而不是崩", rect == .zero)
}
do {
    let display = CGRect(x: 0, y: 0, width: 200, height: 100)
    let corner = ColorGridSampler.viewPoint(CGPoint(x: 0, y: 0), displayRect: display)
    let center = ColorGridSampler.viewPoint(CGPoint(x: 0.5, y: 0.5), displayRect: display)
    let far = ColorGridSampler.viewPoint(CGPoint(x: 1, y: 1), displayRect: display)
    check("归一化左上角 → 视图左上角", corner == .zero)
    check("归一化中心 → 视图中心", center == CGPoint(x: 100, y: 50))
    check("归一化右下角 → 视图右下角", far == CGPoint(x: 200, y: 100))
}

// ═══ 6. 色值格式 ═══
print("\n═══ 6. 色值格式 ═══")
check("0 → #000000", RGBColor(r: 0, g: 0, b: 0).hex == "#000000")
check("1 → #FFFFFF", RGBColor(r: 1, g: 1, b: 1).hex == "#FFFFFF")
check("越界会被夹住", RGBColor(r: -1, g: 2, b: 0.5).hex == "#00FF80",
      RGBColor(r: -1, g: 2, b: 0.5).hex)
check("大写十六进制、定长 7 字符", RGBColor(r: 0.1, g: 0.2, b: 0.3).hex.count == 7)
check("低值不留空位（补零）", RGBColor(r: 1.0 / 255, g: 0, b: 0).hex == "#010000",
      RGBColor(r: 1.0 / 255, g: 0, b: 0).hex)

print("\n═══════════════════════════════════════════════════════")
print("通过 \(passed)  失败 \(failed)")
exit(failed == 0 ? 0 : 1)
