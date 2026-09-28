//
//  TextImagePreprocessor 回归测试
//
//  这一套全是**合成图**：自己画一张点阵字、画一张左暗右亮的渐变底，
//  然后验证预处理真的把该连的连上了、该分开的分开了。
//
//  为什么必须测：这几步全是逐像素操作，"看起来在跑"和"实际上没效果"
//  在外观上没区别 —— 而 OCR 认不出来时，你无法判断是图没处理好
//  还是模型不行。把每一拍的输入输出钉死，才能定位。
//
//  用法：./scripts/run-textpreprocess-tests.sh
//

import CoreGraphics
import Foundation

var passed = 0
var failed = 0

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { passed += 1; print("  ✅ \(label)") }
    else { failed += 1; print("  ❌ \(label)\(detail().isEmpty ? "" : "  → \(detail())")") }
}

// MARK: - 造图工具

/// 灰度图 → BGRA 缓冲（模拟相机帧）。
func bgraBuffer(_ image: GrayImage) -> (pixels: [UInt8], bytesPerRow: Int) {
    let bytesPerRow = image.width * 4
    var out = [UInt8](repeating: 0, count: bytesPerRow * image.height)
    for index in 0..<(image.width * image.height) {
        let value = image.bytes[index]
        let offset = index * 4
        out[offset] = value
        out[offset + 1] = value
        out[offset + 2] = value
        out[offset + 3] = 255
    }
    return (out, bytesPerRow)
}

/// 画一张"点阵字"：每隔一个像素点一个点，模拟喷码。
///
/// 返回 (图, 笔画应有的总像素数)。点之间的水平/垂直间隔由 `gap` 决定。
func makeDotMatrix(
    width: Int,
    height: Int,
    background: UInt8 = 235,
    ink: UInt8 = 40,
    gap: Int = 2,
    dot: Int? = nil,
    origin: (x: Int, y: Int) = (10, 10),
    glyph: (width: Int, height: Int)
) -> GrayImage {
    var bytes = [UInt8](repeating: background, count: width * height)
    // dot 必须能单独指定。默认 gap-1 会让 dot=2 的"点"变成 2×2 小块，
    // 那种块之间是 4-连通的 —— 于是"孤立点"计数恒为 0，
    // 测出来像是算法没效果，其实是造出来的图根本就不是点阵。
    let dotSize = max(1, min(gap, dot ?? (gap - 1)))
    for y in 0..<glyph.height {
        for x in 0..<glyph.width {
            // 每 gap 个像素画 dotSize 个像素 —— 形成点阵
            guard x % gap < dotSize, y % gap < dotSize else { continue }
            let px = origin.x + x
            let py = origin.y + y
            guard px >= 0, px < width, py >= 0, py < height else { continue }
            bytes[py * width + px] = ink
        }
    }
    return GrayImage(width: width, height: height, bytes: bytes)
}

/// 数一张二值图里黑色像素的个数。
func darkCount(_ image: GrayImage) -> Int {
    image.bytes.filter { $0 < 128 }.count
}

/// 数"孤立墨点"：上下左右四邻都没有墨的黑像素。
///
/// 这是判断"点阵有没有连成线"的正确度量。
/// （一开始用的是"被墨包住的白色空洞数"，但 1px 点 + 1px 缝的点阵里，
///   点只在斜角相邻，根本不存在四邻皆墨的白色像素 —— 那个度量恒为 0，
///   结果 3 条断言全部假失败，反而盖住了真正的 bug。）
func isolatedInkPixels(_ image: GrayImage) -> Int {
    var isolated = 0
    for y in 0..<image.height {
        for x in 0..<image.width {
            guard image.value(x: x, y: y) < 128 else { continue }
            let hasNeighbor = image.value(x: x - 1, y: y) < 128
                || image.value(x: x + 1, y: y) < 128
                || image.value(x: x, y: y - 1) < 128
                || image.value(x: x, y: y + 1) < 128
            if !hasNeighbor { isolated += 1 }
        }
    }
    return isolated
}

// ═══ 1. 灰度化 ═══
print("═══ 1. 灰度化（通道权重不能反）═══")
do {
    // 纯红：Rec.709 亮度 ≈ 0.2126 × 255 ≈ 54
    var red = [UInt8](repeating: 0, count: 4)
    red[0] = 0; red[1] = 0; red[2] = 255; red[3] = 255   // BGRA = 纯红
    let redGray = red.withUnsafeBufferPointer { buffer in
        TextImagePreprocessor.grayscale(
            bgra: buffer.baseAddress!, bytesPerRow: 4, width: 1, height: 1
        )
    }
    check("纯红的灰度在 50–58（Rec.709 权重）",
          (50...58).contains(Int(redGray.bytes[0])), "\(redGray.bytes[0])")

    // 纯蓝 ≈ 0.0722 × 255 ≈ 18
    var blue = [UInt8](repeating: 0, count: 4)
    blue[0] = 255; blue[3] = 255
    let blueGray = blue.withUnsafeBufferPointer { buffer in
        TextImagePreprocessor.grayscale(
            bgra: buffer.baseAddress!, bytesPerRow: 4, width: 1, height: 1
        )
    }
    check("纯蓝的灰度在 15–22", (15...22).contains(Int(blueGray.bytes[0])), "\(blueGray.bytes[0])")

    // 纯绿 ≈ 0.7152 × 255 ≈ 182
    var green = [UInt8](repeating: 0, count: 4)
    green[1] = 255; green[3] = 255
    let greenGray = green.withUnsafeBufferPointer { buffer in
        TextImagePreprocessor.grayscale(
            bgra: buffer.baseAddress!, bytesPerRow: 4, width: 1, height: 1
        )
    }
    check("纯绿最亮（绿权重最高）", Int(greenGray.bytes[0]) > Int(redGray.bytes[0]),
          "绿 \(greenGray.bytes[0]) vs 红 \(redGray.bytes[0])")
    check("红比蓝亮（权重顺序对）", Int(redGray.bytes[0]) > Int(blueGray.bytes[0]))
}
do {
    // 带行填充的缓冲也不能读错
    let width = 6, height = 3, padding = 12
    let bytesPerRow = width * 4 + padding
    var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
    for index in 0..<(width * height) {
        let y = index / width, x = index % width
        let offset = y * bytesPerRow + x * 4
        pixels[offset] = 100; pixels[offset + 1] = 100; pixels[offset + 2] = 100
    }
    let gray = pixels.withUnsafeBufferPointer { buffer in
        TextImagePreprocessor.grayscale(
            bgra: buffer.baseAddress!, bytesPerRow: bytesPerRow,
            width: width, height: height
        )
    }
    check("有行填充时每行都读对", gray.bytes.allSatisfy { $0 == 100 },
          "\(Set(gray.bytes).sorted())")
}

// ═══ 2. 放大 ═══
print("\n═══ 2. 放大（治「字太小」）═══")
do {
    let source = GrayImage(width: 3, height: 2, bytes: [0, 128, 255, 255, 128, 0])
    let doubled = TextImagePreprocessor.upscale(source, factor: 2)
    check("尺寸翻倍", doubled.width == 6 && doubled.height == 4,
          "\(doubled.width)×\(doubled.height)")
    check("角上的值保留", doubled.value(x: 0, y: 0) == 0 && doubled.value(x: 5, y: 3) == 0)
    check("四角都对得上",
          doubled.value(x: 5, y: 0) == 255 && doubled.value(x: 0, y: 3) == 255,
          "右上 \(doubled.value(x: 5, y: 0)) 左下 \(doubled.value(x: 0, y: 3))")
    check("中间是插值出来的灰（不是硬边）",
          doubled.bytes.contains { $0 > 10 && $0 < 245 }, "\(Set(doubled.bytes).sorted())")
}
do {
    let source = GrayImage(width: 4, height: 4, bytes: [UInt8](repeating: 90, count: 16))
    let scaled = TextImagePreprocessor.upscale(source, factor: 1)
    check("factor=1 原样返回", scaled.bytes == source.bytes)
    let big = TextImagePreprocessor.upscale(source, factor: 3)
    check("factor=3 尺寸正确", big.width == 12 && big.height == 12)
    check("纯色放大后还是纯色", Set(big.bytes) == Set([90]), "\(Set(big.bytes))")
}

// ═══ 3. 对比度均衡 ═══
print("\n═══ 3. 对比度均衡（拉开笔画与底色）═══")
do {
    // 一张"灰蒙蒙"的图：前景 120、背景 140，差距很小
    var bytes = [UInt8](repeating: 140, count: 20 * 20)
    for y in 5..<15 { for x in 5..<15 { bytes[y * 20 + x] = 120 } }
    let flat = GrayImage(width: 20, height: 20, bytes: bytes)
    let equalized = TextImagePreprocessor.equalize(flat)

    let foreground = equalized.value(x: 10, y: 10)
    let background = equalized.value(x: 1, y: 1)
    // ⚠️ 不能断言"前景变成某个具体值"：均衡是按**累积分布**重新分配灰度的。
    //    这张图前景只占 25% 的像素，所以它被映射到 0…64 那一段，
    //    而不是 0。该断言的是"两者被推开了"。
    check("均衡后前景落进暗部（下 1/3）", foreground < 90, "\(foreground)")
    check("均衡后背景落进亮部（上 1/3）", background > 165, "\(background)")
    check("对比度被明显拉开（原图只差 20）",
          Int(background) - Int(foreground) > 100,
          "差 \(Int(background) - Int(foreground))")
}
do {
    let uniform = GrayImage(width: 8, height: 8, bytes: [UInt8](repeating: 128, count: 64))
    let equalized = TextImagePreprocessor.equalize(uniform)
    check("纯色图均衡后不崩、不变成噪声", Set(equalized.bytes).count == 1,
          "\(Set(equalized.bytes))")
}

// ═══ 4. 局部自适应二值化 ═══
print("\n═══ 4. 局部自适应二值化（治「明暗不均」）═══")
do {
    // 左半背景 60、右半背景 220（模拟圆柱面反光），文字都比各自背景暗 30
    var bytes = [UInt8](repeating: 0, count: 60 * 40)
    for y in 0..<40 {
        for x in 0..<60 {
            let background: UInt8 = x < 30 ? 60 : 220
            bytes[y * 60 + x] = background
        }
    }
    // 在两侧各画一条竖线作为"笔画"。
    // 注意对比度：亮区笔画原来填 190，而那里局部背景是 220 ——
    // 只暗了 14%，低于 k=0.15 的检出线，测出来当然是 255。
    // 那是测试数据造的坑，不是算法问题。真实笔画至少比底色暗两成。
    for y in 10..<30 {
        bytes[y * 60 + 10] = 30    // 暗区：底 60，暗 50%
        bytes[y * 60 + 44] = 180   // 亮区：底 220，暗 18%
    }
    let uneven = GrayImage(width: 60, height: 40, bytes: bytes)
    let binary = TextImagePreprocessor.adaptiveBinarize(uneven, radius: 8, k: 0.15)

    check("暗区里的笔画被认出来", binary.value(x: 10, y: 20) == 0,
          "\(binary.value(x: 10, y: 20))")
    check("亮区里的笔画也被认出来（全局阈值这里会失败）",
          binary.value(x: 44, y: 20) == 0, "\(binary.value(x: 44, y: 20))")
    check("暗区背景保持白", binary.value(x: 20, y: 5) == 255)
    check("亮区背景保持白", binary.value(x: 55, y: 5) == 255)
    check("输出只有 0 和 255", Set(binary.bytes).isSubset(of: [0, 255]),
          "\(Set(binary.bytes).sorted())")
}
do {
    // 纯色图不该被二值化出噪声
    let uniform = GrayImage(width: 30, height: 30, bytes: [UInt8](repeating: 128, count: 900))
    let binary = TextImagePreprocessor.adaptiveBinarize(uniform, radius: 5)
    check("纯色图二值化后全白（不产生假笔画）", Set(binary.bytes) == Set([255]),
          "\(Set(binary.bytes))")
}

// ═══ 5. 形态学闭运算（专门治点阵喷码）═══
print("\n═══ 5. 闭运算（把点阵的点连成笔画）═══")
do {
    // 造一个"点阵"字：每隔 2 像素一个 1px 点（1px 缝）
    let dots = makeDotMatrix(
        width: 40, height: 40, gap: 2,
        origin: (8, 8), glyph: (width: 16, height: 16)
    )
    // 先二值化得到干净的点阵（背景白、点是黑）
    let binary = TextImagePreprocessor.adaptiveBinarize(dots, radius: 6, k: 0.15)
    let beforeIsolated = isolatedInkPixels(binary)
    check("点阵图里绝大多数墨点是孤立的", beforeIsolated > 40, "\(beforeIsolated) 个孤立点")

    let closed = TextImagePreprocessor.close(binary, radius: 1)
    let afterIsolated = isolatedInkPixels(closed)
    check("闭运算后孤立点大幅减少（点连成了线）",
          afterIsolated < beforeIsolated / 2,
          "前 \(beforeIsolated) → 后 \(afterIsolated)")

    let beforeDark = darkCount(binary)
    let afterDark = darkCount(closed)
    check("闭运算后墨量不减（没被擦掉 —— 极性写反时这里会变成 0）",
          afterDark >= beforeDark, "前 \(beforeDark) → 后 \(afterDark)")
    check("但也没把整幅图涂黑",
          Double(afterDark) < Double(binary.width * binary.height) * 0.8,
          "\(afterDark) / \(binary.width * binary.height)")
}
do {
    // 真正的孤立点阵：1px 点、2px 缝（间隔 3）
    let dots = makeDotMatrix(
        width: 60, height: 60, gap: 3, dot: 1,
        origin: (10, 10), glyph: (width: 24, height: 24)
    )
    let binary = TextImagePreprocessor.adaptiveBinarize(dots, radius: 6, k: 0.15)
    let beforeUpscale = isolatedInkPixels(binary)

    // 2 倍双线性放大本身就会把 1px 的缝糊掉一部分 ——
    // 这是"放大"这一拍顺带的好处，也正是它排在闭运算前面的原因。
    let enlarged = TextImagePreprocessor.upscale(binary, factor: 2)
    let afterUpscale = isolatedInkPixels(enlarged)
    check("放大本身就能减少孤立点（插值把缝糊上了）",
          afterUpscale < beforeUpscale, "前 \(beforeUpscale) → 后 \(afterUpscale)")

    let closed = TextImagePreprocessor.close(enlarged, radius: 2)
    check("再叠一层闭运算：孤立点继续减少或持平",
          isolatedInkPixels(closed) <= afterUpscale,
          "\(afterUpscale) → \(isolatedInkPixels(closed))")
    // 关键：闭运算不能把墨擦掉（极性写反时这里会是 0）
    check("墨量没有消失", darkCount(closed) > 0, "\(darkCount(closed))")
    check("墨量比纯放大还多一点（膨胀留下的）",
          darkCount(closed) >= darkCount(enlarged), "\(darkCount(enlarged)) → \(darkCount(closed))")
}
do {
    // 闭运算不该改变实心块的尺寸（这是闭运算的定义）
    var bytes = [UInt8](repeating: 255, count: 30 * 30)
    for y in 10..<20 { for x in 10..<20 { bytes[y * 30 + x] = 0 } }
    let square = GrayImage(width: 30, height: 30, bytes: bytes)
    let closed = TextImagePreprocessor.close(square, radius: 2)
    // 检查原方块四角仍是黑、方块外一格仍是白
    check("实心块的四角还是黑", closed.value(x: 10, y: 10) == 0
          && closed.value(x: 19, y: 19) == 0)
    check("实心块外一格还是白（尺寸没被撑大）",
          closed.value(x: 8, y: 15) == 255 && closed.value(x: 21, y: 15) == 255)
}
do {
    let source = GrayImage(width: 10, height: 10, bytes: [UInt8](repeating: 128, count: 100))
    check("radius=0 时原样返回",
          TextImagePreprocessor.close(source, radius: 0).bytes == source.bytes)
}
do {
    // 可分离滤波的正确性：单行点阵应该被横向连起来
    var bytes = [UInt8](repeating: 255, count: 20 * 3)
    for x in stride(from: 2, to: 18, by: 2) { bytes[1 * 20 + x] = 0 }
    let row = GrayImage(width: 20, height: 3, bytes: bytes)
    let dilated = TextImagePreprocessor.erodeOrDilate(row, radius: 1, takeMax: false)
    // 腐蚀后黑点应该连成一条线（原来是隔一个）
    var darkInMiddleRow = 0
    for x in 0..<20 where dilated.value(x: x, y: 1) == 0 { darkInMiddleRow += 1 }
    check("横向连起来了（隔点变连续）", darkInMiddleRow >= 8, "\(darkInMiddleRow) 个黑点")
}

// ═══ 6. 裁剪（数码变焦）═══
print("\n═══ 6. 裁剪 / 数码变焦 ═══")
do {
    var bytes = [UInt8](repeating: 255, count: 40 * 40)
    for y in 10..<20 { for x in 10..<20 { bytes[y * 40 + x] = 0 } }
    let image = GrayImage(width: 40, height: 40, bytes: bytes)

    let center = TextImagePreprocessor.crop(image, normalizedRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    check("裁中央 50% → 20×20", center.width == 20 && center.height == 20,
          "\(center.width)×\(center.height)")
    check("被裁掉的黑块还在（它本来就在中央）", darkCount(center) == 100, "\(darkCount(center))")

    let corner = TextImagePreprocessor.crop(image, normalizedRect: CGRect(x: 0, y: 0, width: 0.25, height: 0.25))
    check("裁左上角 → 10×10", corner.width == 10 && corner.height == 10)
    check("左上角没有黑块", darkCount(corner) == 0, "\(darkCount(corner))")

    let full = TextImagePreprocessor.crop(image, normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))
    check("裁全幅 = 原图", full.bytes == image.bytes)
}
do {
    let image = GrayImage(width: 10, height: 10, bytes: [UInt8](repeating: 200, count: 100))
    let empty = TextImagePreprocessor.crop(image, normalizedRect: CGRect(x: 0.9, y: 0.9, width: 0.01, height: 0.01))
    check("极小的裁剪框不崩", !empty.isEmpty || empty.width >= 0)
}

// ═══ 7. 回写 BGRA ═══
print("\n═══ 7. 回写成 BGRA ═══")
do {
    let gray = GrayImage(width: 2, height: 1, bytes: [0, 255])
    let bgra = TextImagePreprocessor.bgra(fromGray: gray)
    check("长度 = 像素数 × 4", bgra.count == 8, "\(bgra.count)")
    check("第一个像素三通道相同（灰度）",
          bgra[0] == gray.bytes[0] && bgra[1] == gray.bytes[0] && bgra[2] == gray.bytes[0])
    check("alpha 是 255", bgra[3] == 255 && bgra[7] == 255)
    check("第二个像素是白的", bgra[4] == 255 && bgra[5] == 255 && bgra[6] == 255)
}

// ═══ 8. 完整流水线 ═══
print("\n═══ 8. 完整流水线（端到端）═══")
do {
    // 造一张"点阵喷码 + 明暗不均"的图：这正是用户遇到的情况
    var bytes = [UInt8](repeating: 0, count: 120 * 60)
    for y in 0..<60 {
        for x in 0..<120 {
            // 左暗右亮的渐变背景
            bytes[y * 120 + x] = UInt8(60 + x * 140 / 120)
        }
    }
    // 点阵笔画：左侧一组、右侧一组。
    // 右侧原来填 180，但那里局部背景只有 160–177 ——
    // "笔画"比背景还亮，自适应二值化当然检不出来（那是测试数据的错）。
    // 正确造法：两处笔画都比**各自的局部背景**暗两成以上。
    for y in stride(from: 20, to: 40, by: 2) {
        for x in stride(from: 15, to: 30, by: 2) {
            bytes[y * 120 + x] = 25              // 局部背景 ≈ 78，暗 68%
        }
        for x in stride(from: 85, to: 100, by: 2) {
            let localBackground = 60 + x * 140 / 120   // ≈ 159…177
            bytes[y * 120 + x] = UInt8(max(0, localBackground - 55))
        }
    }
    let raw = GrayImage(width: 120, height: 60, bytes: bytes)
    let buffer = bgraBuffer(raw)

    let result = buffer.pixels.withUnsafeBufferPointer { pointer in
        TextImagePreprocessor.process(
            bgra: pointer.baseAddress!, bytesPerRow: buffer.bytesPerRow,
            width: 120, height: 60, profile: .dotMatrix
        )
    }
    check("流水线有输出", result != nil)
    if let result {
        check("放大 2 倍 → 240×120", result.width == 240 && result.height == 120,
              "\(result.width)×\(result.height)")
        check("输出是 BGRA（长度 = 像素 × 4）",
              result.pixels.count == result.width * result.height * 4)

        // 把结果当灰度看（三通道相同），验证明暗两处的笔画都变黑了
        let gray = GrayImage(width: result.width, height: result.height,
                             bytes: stride(from: 0, to: result.pixels.count, by: 4).map { result.pixels[$0] })
        // 原来左侧笔画在 x=15..30, y=20..40（缩放后 x=30..60, y=40..80）
        let darkLeft = (40..<80).flatMap { y in (30..<60).map { x in gray.value(x: x, y: y) } }
            .filter { $0 < 128 }.count
        // 右侧笔画原来在 x=85..100（缩放后 x=170..200）
        let darkRight = (40..<80).flatMap { y in (170..<200).map { x in gray.value(x: x, y: y) } }
            .filter { $0 < 128 }.count

        check("暗区的点阵被认成笔画", darkLeft > 50, "\(darkLeft) 个黑像素")
        check("亮区的点阵也被认成笔画（这是关键）", darkRight > 50, "\(darkRight) 个黑像素")
    }
}
do {
    // 数码变焦 + 点阵档位
    let raw = makeDotMatrix(width: 80, height: 80, gap: 2, origin: (30, 30), glyph: (20, 20))
    let buffer = bgraBuffer(raw)
    let zoomed = buffer.pixels.withUnsafeBufferPointer { pointer in
        TextImagePreprocessor.process(
            bgra: pointer.baseAddress!, bytesPerRow: buffer.bytesPerRow,
            width: 80, height: 80, profile: .dotMatrix, zoom: 2
        )
    }
    check("变焦 2 倍 + 放大 2 倍 → 80×80",
          zoomed?.width == 80 && zoomed?.height == 80,
          "\(zoomed?.width ?? -1)×\(zoomed?.height ?? -1)")
}
do {
    let raw = GrayImage(width: 20, height: 20, bytes: [UInt8](repeating: 128, count: 400))
    let buffer = bgraBuffer(raw)
    let none = buffer.pixels.withUnsafeBufferPointer { pointer in
        TextImagePreprocessor.process(
            bgra: pointer.baseAddress!, bytesPerRow: buffer.bytesPerRow,
            width: 20, height: 20, profile: .none
        )
    }
    check("profile=.none 时尺寸不变", none?.width == 20 && none?.height == 20)
}

// ═══ 9. 点阵可能性判断 ═══
print("\n═══ 9. 点阵可能性判断 ═══")
do {
    let dots = makeDotMatrix(width: 100, height: 40, gap: 2, origin: (6, 6), glyph: (40, 20))
    let dotScore = TextImagePreprocessor.dotMatrixLikelihood(dots)

    // 实心印刷体：连续的长笔画
    var solidBytes = [UInt8](repeating: 235, count: 100 * 40)
    for y in 8..<30 {
        for x in 6..<46 { solidBytes[y * 100 + x] = 40 }
    }
    let solid = GrayImage(width: 100, height: 40, bytes: solidBytes)
    let solidScore = TextImagePreprocessor.dotMatrixLikelihood(solid)

    check("点阵图得分更高", dotScore > solidScore,
          "点阵 \(String(format: "%.2f", dotScore)) vs 实心 \(String(format: "%.2f", solidScore))")
    check("实心印刷体得分很低", solidScore < 0.35, String(format: "%.2f", solidScore))
    check("得分在 0…1 之间", (0...1).contains(dotScore) && (0...1).contains(solidScore))
}
do {
    let blank = GrayImage(width: 20, height: 20, bytes: [UInt8](repeating: 240, count: 400))
    check("空白图不给结论（返回 0）",
          TextImagePreprocessor.dotMatrixLikelihood(blank) == 0)
}

print("\n═══════════════════════════════════════════════════════")
print("通过 \(passed)  失败 \(failed)")
exit(failed == 0 ? 0 : 1)
