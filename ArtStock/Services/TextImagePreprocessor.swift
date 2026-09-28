//
//  TextImagePreprocessor.swift
//  ArtAssist — 美术生的工具箱
//
//  给 OCR 做图像预处理。**专门针对工业喷码字体。**
//
//  ── 喷码为什么难认 ───────────────────────────────────────────
//  工业喷码（点阵喷码）跟印刷体是两种东西，Vision 是按后者训练的：
//
//    · **字是点拼出来的**。喷头一个脉冲一个点，笔画之间有 1–4 px 的空隙。
//      Vision 看到的是"一堆孤立的点"，不是"一个字"。
//    · **字很小**。管子上那行批号常常只有 1–2 mm 高。
//      一帧 1920×1080 里它可能只占 12 px —— 低于模型能分辨的下限。
//    · **明暗不均**。颜料管是圆柱面，还反光，同一条码上一半过曝一半欠曝。
//      全局阈值一卡就断成两截。
//    · **不是词**。批号是 `20250612A3` 这种，语言纠正反而会"纠正"成别的。
//
//  对应的四步处理，每一步都是冲着一个具体毛病去的：
//
//    ┌ 放大 2–3 倍       → 治"字太小"（bilinear 顺手把点之间的缝隙糊上一半）
//    ├ 对比度均衡        → 治"明暗不均"的第一层
//    ├ 局部自适应二值化  → 治"明暗不均"（每个像素跟**自己邻域**的均值比，
//    │                     而不是跟整幅图的阈值比）
//    └ 形态学闭运算      → 治"字是点拼的"（先膨胀把点连起来，再腐蚀回原粗细）
//
//  ── 为什么不用现成的图像库 ───────────────────────────────────
//  这四步都是几十行的事，而且**必须是纯函数** ——
//  只有这样才能用合成出来的点阵图跑回归测试（见 Tests/TextPreprocessTests）。
//  引一个库反而没法测：库的实现细节不是我能钉住的。
//
//  ── 和"上模型"的关系 ────────────────────────────────────────
//  预处理是**任何** OCR 模型的前置。就算以后换成 PaddleOCR 那种专门模型，
//  这四步照样要做 —— 喂给模型的原图质量决定上限。
//  所以它先做，而且做在模型前面。
//

import CoreGraphics
import Foundation

/// 8 位灰度图。宽高之外不假设任何内存布局。
struct GrayImage: Equatable {
    var width: Int
    var height: Int
    /// 长度 = width × height，行优先。
    var bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.bytes = bytes
    }

    var isEmpty: Bool { width <= 0 || height <= 0 || bytes.count < width * height }

    @inline(__always)
    func value(x: Int, y: Int) -> UInt8 {
        guard x >= 0, x < width, y >= 0, y < height else { return 255 }
        return bytes[y * width + x]
    }
}

enum TextImagePreprocessor {

    // MARK: - 1. 灰度化

    /// BGRA 缓冲 → 灰度。
    ///
    /// 用 Rec.709 亮度权重（0.2126/0.7152/0.0722）而不是简单平均：
    /// 简单平均会把饱和的红和蓝算成同一个灰度，而喷码常用红色或蓝色油墨。
    static func grayscale(
        bgra: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        width: Int,
        height: Int
    ) -> GrayImage {
        guard width > 0, height > 0 else { return GrayImage(width: 0, height: 0, bytes: []) }
        var out = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * bytesPerRow
            let outRow = y * width
            for x in 0..<width {
                let offset = row + x * 4
                let b = Int(bgra[offset])
                let g = Int(bgra[offset + 1])
                let r = Int(bgra[offset + 2])
                // 整数运算，避免每像素一次浮点乘法
                let luma = (r * 54 + g * 183 + b * 19) >> 8
                out[outRow + x] = UInt8(min(255, max(0, luma)))
            }
        }
        return GrayImage(width: width, height: height, bytes: out)
    }

    // MARK: - 2. 放大

    /// 双线性放大整数倍。
    ///
    /// 顺手有第二个好处：点阵笔画之间的缝隙会被插值糊掉一部分，
    /// 相当于在做闭运算之前先连了一半。
    static func upscale(_ image: GrayImage, factor: Int) -> GrayImage {
        guard !image.isEmpty, factor > 1 else { return image }
        let newWidth = image.width * factor
        let newHeight = image.height * factor
        var out = [UInt8](repeating: 255, count: newWidth * newHeight)

        for y in 0..<newHeight {
            // 源坐标（以像素中心对齐，避免整体偏移半格）
            let sy = (Double(y) + 0.5) / Double(factor) - 0.5
            let y0 = max(0, min(image.height - 1, Int(sy.rounded(.down))))
            let y1 = min(image.height - 1, y0 + 1)
            let fy = max(0, min(1, sy - Double(y0)))

            for x in 0..<newWidth {
                let sx = (Double(x) + 0.5) / Double(factor) - 0.5
                let x0 = max(0, min(image.width - 1, Int(sx.rounded(.down))))
                let x1 = min(image.width - 1, x0 + 1)
                let fx = max(0, min(1, sx - Double(x0)))

                let v00 = Double(image.value(x: x0, y: y0))
                let v10 = Double(image.value(x: x1, y: y0))
                let v01 = Double(image.value(x: x0, y: y1))
                let v11 = Double(image.value(x: x1, y: y1))

                let top = v00 + (v10 - v00) * fx
                let bottom = v01 + (v11 - v01) * fx
                let value = top + (bottom - top) * fy
                out[y * newWidth + x] = UInt8(min(255, max(0, value.rounded())))
            }
        }
        return GrayImage(width: newWidth, height: newHeight, bytes: out)
    }

    // MARK: - 3. 对比度均衡

    /// 直方图均衡。
    ///
    /// 喷码常常只占很小一块区域，整体对比度很低（灰蒙蒙）。
    /// 均衡把灰度铺满整个范围，笔画与底色的差距就被拉开了。
    static func equalize(_ image: GrayImage) -> GrayImage {
        guard !image.isEmpty else { return image }
        var histogram = [Int](repeating: 0, count: 256)
        for value in image.bytes { histogram[Int(value)] += 1 }

        let total = image.bytes.count
        var cumulative = [Int](repeating: 0, count: 256)
        var running = 0
        for index in 0..<256 {
            running += histogram[index]
            cumulative[index] = running
        }

        // 找到实际的最小/最大灰度，只在那一段上拉伸 ——
        // 直接对全 0–255 做累积映射会把纯黑纯白也算进去，对比反而不动。
        var minValue = 0
        while minValue < 255, cumulative[minValue] == 0 { minValue += 1 }
        var maxValue = 255
        while maxValue > minValue, cumulative[maxValue] == total { maxValue -= 1 }

        guard maxValue > minValue else { return image }

        var lut = [UInt8](repeating: 0, count: 256)
        let lowCount = minValue == 0 ? 0 : cumulative[minValue - 1]
        let span = max(1, total - lowCount)
        for index in 0..<256 {
            let clamped = min(span, max(0, cumulative[index] - lowCount))
            let mapped = Int((Double(clamped) / Double(span) * 255).rounded())
            lut[index] = UInt8(min(255, max(0, mapped)))
        }

        return GrayImage(width: image.width, height: image.height,
                         bytes: image.bytes.map { lut[Int($0)] })
    }

    // MARK: - 4. 局部自适应二值化

    /// 局部均值自适应二值化（Bradley–Roth 那一类）。
    ///
    /// 每个像素跟**自己邻域**的平均灰度比：
    ///     像素 < 邻域均值 × (1 − k)  →  笔画（黑）
    ///     否则                         →  背景（白）
    ///
    /// 这就是"同一个条码上一半过曝一半欠曝"也能整条读出来的原因 ——
    /// 全局阈值在过曝区会把整块判成白。
    ///
    /// - Parameters:
    ///   - radius: 邻域半径（像素）。应大于笔画宽度、小于字与字的间距。
    ///   - k: 灵敏度。0.15 左右适合点阵喷码（笔画比背景暗一些但不多）。
    /// - Returns: 只含 0 与 255 的图。
    static func adaptiveBinarize(_ image: GrayImage, radius: Int, k: Double = 0.15) -> GrayImage {
        guard !image.isEmpty else { return image }
        let r = max(1, radius)
        let width = image.width
        let height = image.height

        // 积分图：任意矩形和 O(1)
        var integral = [Int](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var rowSum = 0
            for x in 0..<width {
                rowSum += Int(image.bytes[y * width + x])
                integral[(y + 1) * (width + 1) + (x + 1)] = integral[y * (width + 1) + (x + 1)] + rowSum
            }
        }

        func windowSum(x0: Int, y0: Int, x1: Int, y1: Int) -> Int {
            let ax = max(0, min(width, x0))
            let ay = max(0, min(height, y0))
            let bx = max(0, min(width, x1))
            let by = max(0, min(height, y1))
            return integral[by * (width + 1) + bx]
                - integral[ay * (width + 1) + bx]
                - integral[by * (width + 1) + ax]
                + integral[ay * (width + 1) + ax]
        }

        var out = [UInt8](repeating: 255, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let x0 = x - r, y0 = y - r
                let x1 = x + r + 1, y1 = y + r + 1
                let sum = windowSum(x0: x0, y0: y0, x1: x1, y1: y1)

                let clampedX0 = max(0, x0), clampedY0 = max(0, y0)
                let clampedX1 = min(width, x1), clampedY1 = min(height, y1)
                let count = max(1, (clampedX1 - clampedX0) * (clampedY1 - clampedY0))

                let mean = Double(sum) / Double(count)
                let threshold = mean * (1 - k)
                out[y * width + x] = Double(image.bytes[y * width + x]) < threshold ? 0 : 255
            }
        }
        return GrayImage(width: width, height: height, bytes: out)
    }

    // MARK: - 5. 形态学闭运算

    /// 闭运算 = 先膨胀再腐蚀。
    ///
    /// **这一步是专门为点阵喷码加的。** 膨胀把笔画之间的点连成一条线，
    /// 腐蚀再把线收回到原来的粗细。结果是"点阵"变成了"实心笔画"，
    /// 而整体位置和粗细基本不变（这也是闭运算的定义）。
    ///
    /// 用可分离的最大值/最小值滤波（先按行后按列）：
    /// 朴素实现是 O(w·h·r²)，可分离之后是 O(w·h·r)。
    /// 一张 1080p 的图，r=2 时省掉约 10 倍的运算。
    ///
    /// - Parameter radius: 结构元素半径（像素）。点阵缝隙通常是 1–3 px，
    ///   放大 2 倍之后用 2 比较合适。
    static func close(_ image: GrayImage, radius: Int) -> GrayImage {
        guard !image.isEmpty, radius > 0 else { return image }
        // 先让墨长大（把点连起来），再让它缩回原来的粗细
        return shrinkInk(growInk(image, radius: radius), radius: radius)
    }

    /// 让墨变粗（数学形态学的"膨胀"）。
    ///
    /// ⚠️ 取**最小值**，不是最大值。
    ///    这个表示法里"墨 = 0（黑）、底 = 255（白）"，也就是**前景是小的那个值**。
    ///    而标准形态学的例子默认"前景 = 1"，于是膨胀 = 取最大值。
    ///    极性照搬过来正好会反：取最大值是让**白**长大，也就是把笔画擦掉。
    ///    （这个 bug 真写过一次，被合成图的测试当场抓出来：黑像素 64 → 0。）
    static func growInk(_ image: GrayImage, radius: Int) -> GrayImage {
        erodeOrDilate(image, radius: radius, takeMax: false)
    }

    /// 让墨变细（数学形态学的"腐蚀"）。取最大值 —— 让白长大。
    static func shrinkInk(_ image: GrayImage, radius: Int) -> GrayImage {
        erodeOrDilate(image, radius: radius, takeMax: true)
    }

    /// 极值滤波。
    ///
    /// - Parameter takeMax: true 取邻域最大值（白长大），false 取最小值（墨长大）。
    ///   调用方请用 `growInk` / `shrinkInk`，不要直接用这个 ——
    ///   名字里的 max/min 和"墨变粗还是变细"是反的，很容易搞混。
    static func erodeOrDilate(_ image: GrayImage, radius: Int, takeMax: Bool) -> GrayImage {
        guard !image.isEmpty, radius > 0 else { return image }
        let width = image.width
        let height = image.height
        var horizontal = [UInt8](repeating: 0, count: width * height)

        // 先按行
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var value = takeMax ? UInt8(0) : UInt8(255)
                let from = max(0, x - radius)
                let to = min(width - 1, x + radius)
                for sx in from...to {
                    let candidate = image.bytes[row + sx]
                    if takeMax { value = max(value, candidate) } else { value = min(value, candidate) }
                }
                horizontal[row + x] = value
            }
        }

        // 再按列
        var out = [UInt8](repeating: 0, count: width * height)
        for x in 0..<width {
            for y in 0..<height {
                var value = takeMax ? UInt8(0) : UInt8(255)
                let from = max(0, y - radius)
                let to = min(height - 1, y + radius)
                for sy in from...to {
                    let candidate = horizontal[sy * width + x]
                    if takeMax { value = max(value, candidate) } else { value = min(value, candidate) }
                }
                out[y * width + x] = value
            }
        }
        return GrayImage(width: width, height: height, bytes: out)
    }

    // MARK: - 6. 裁剪（数字变焦）

    /// 按归一化矩形裁剪。
    ///
    /// 用途：喷码太小的时候，用户点一下「放大识别」，
    /// 只取画面中间那块送去识别 —— 相当于数码变焦。
    /// 真正的收益不是"变大"，而是**同样的字占了更多像素**。
    static func crop(_ image: GrayImage, normalizedRect: CGRect) -> GrayImage {
        guard !image.isEmpty else { return image }
        let x0 = max(0, Int((normalizedRect.minX * Double(image.width)).rounded(.down)))
        let y0 = max(0, Int((normalizedRect.minY * Double(image.height)).rounded(.down)))
        let x1 = min(image.width, Int((normalizedRect.maxX * Double(image.width)).rounded(.up)))
        let y1 = min(image.height, Int((normalizedRect.maxY * Double(image.height)).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return image }

        let newWidth = x1 - x0
        let newHeight = y1 - y0
        var out = [UInt8](repeating: 255, count: newWidth * newHeight)
        for y in 0..<newHeight {
            for x in 0..<newWidth {
                out[y * newWidth + x] = image.bytes[(y0 + y) * image.width + (x0 + x)]
            }
        }
        return GrayImage(width: newWidth, height: newHeight, bytes: out)
    }

    // MARK: - 7. 回写成 BGRA

    /// 灰度 → BGRA（Vision 要的输入格式之一）。
    static func bgra(fromGray image: GrayImage) -> [UInt8] {
        guard !image.isEmpty else { return [] }
        var out = [UInt8](repeating: 255, count: image.width * image.height * 4)
        for index in 0..<(image.width * image.height) {
            let value = image.bytes[index]
            let offset = index * 4
            out[offset] = value      // B
            out[offset + 1] = value  // G
            out[offset + 2] = value  // R
            out[offset + 3] = 255    // A
        }
        return out
    }

    // MARK: - 流水线

    /// 预处理档位。
    enum Profile: String, CaseIterable, Sendable {
        /// 不动。给印刷体用，喷码模式下不该用。
        case none
        /// 只放大 + 均衡。笔画本来就是实心的（不是点阵）时用这个。
        case enhance
        /// 完整流水线：放大 → 均衡 → 自适应二值化 → 闭运算。给点阵喷码用。
        case dotMatrix

        var displayName: String {
            switch self {
            case .none: return "原图"
            case .enhance: return "增强"
            case .dotMatrix: return "点阵喷码"
            }
        }
    }

    /// 按档位跑一遍流水线。
    ///
    /// - Parameters:
    ///   - zoom: 数码变焦倍数（1 = 不裁）。
    ///   - roi: 归一化裁剪框。传 nil 且 zoom > 1 时取画面中央。
    static func process(
        bgra: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        width: Int,
        height: Int,
        profile: Profile,
        zoom: Int = 1,
        roi: CGRect? = nil
    ) -> (pixels: [UInt8], width: Int, height: Int)? {
        guard width > 0, height > 0 else { return nil }
        var gray = grayscale(bgra: bgra, bytesPerRow: bytesPerRow, width: width, height: height)

        // 数码变焦：先裁，再放大 —— 顺序反了就白放大
        if zoom > 1 {
            let rect = roi ?? CGRect(
                x: 0.5 - 0.5 / Double(zoom),
                y: 0.5 - 0.5 / Double(zoom),
                width: 1.0 / Double(zoom),
                height: 1.0 / Double(zoom)
            )
            gray = crop(gray, normalizedRect: rect)
        }

        switch profile {
        case .none:
            break
        case .enhance:
            gray = upscale(gray, factor: 2)
            gray = equalize(gray)
        case .dotMatrix:
            gray = upscale(gray, factor: 2)
            gray = equalize(gray)
            gray = adaptiveBinarize(gray, radius: max(6, gray.width / 40), k: 0.15)
            gray = close(gray, radius: 2)
        }

        guard !gray.isEmpty else { return nil }
        // ⚠️ 必须写 `Self.` —— 参数名 `bgra` 把同名的静态方法遮住了，
        //    不限定的话编译器会以为在调用那个 UnsafePointer 参数。
        return (Self.bgra(fromGray: gray), gray.width, gray.height)
    }

    // MARK: - 质量判断

    /// 粗判"这看起来是不是点阵喷码"。
    ///
    /// 判据：**笔画里有多少孤立的短横段**。点阵字的笔画会被切成很多小段，
    /// 印刷体则是连续的长段。用行方向的游程长度分布来判断。
    ///
    /// 返回 0…1，越大越像点阵。用来在界面上给建议，或者自动挑预处理档位。
    /// 刻意做得保守：判错的代价是"用错预处理"，不如让用户自己切换。
    static func dotMatrixLikelihood(_ image: GrayImage) -> Double {
        guard !image.isEmpty else { return 0 }
        // 先二值化，再看黑色游程
        let binary = adaptiveBinarize(equalize(image), radius: max(6, image.width / 40), k: 0.15)

        var shortRuns = 0
        var longRuns = 0
        for y in 0..<binary.height {
            var run = 0
            for x in 0..<binary.width {
                if binary.bytes[y * binary.width + x] == 0 {
                    run += 1
                } else {
                    if run > 0 {
                        if run <= 3 { shortRuns += 1 } else { longRuns += 1 }
                    }
                    run = 0
                }
            }
            if run > 0 {
                if run <= 3 { shortRuns += 1 } else { longRuns += 1 }
            }
        }

        let total = shortRuns + longRuns
        guard total >= 20 else { return 0 }   // 样本太少不下结论
        return Double(shortRuns) / Double(total)
    }
}
