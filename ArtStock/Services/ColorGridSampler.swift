//
//  ColorGridSampler.swift
//  ArtAssist — 美术生的工具箱
//
//  从相机画面里把一整盒 42 格的真实颜色采下来。
//
//  ── 为什么要做这个 ───────────────────────────────────────────
//  真实反馈：「像马尔代夫就根本不像啊颜色，是个绿色的，显示个蓝色的」。
//
//  这条反馈是对的，而且暴露了一个更根本的问题：
//  「马尔代夫」「起司」「浅蟹灰」这些是**品牌自创色名**，
//  马利、米娅、温莎各家调出来的都不一样，网上也没有公开色值。
//  我当初照 W3C 的 turquoise 硬套 —— 套出来当然是蓝的。
//
//  所以这 19 个品牌色**不该由我编**，该从你的实物上采。
//  这个文件就是"采"的算法。
//
//  ── 设计约束 ─────────────────────────────────────────────────
//  这个文件**只用 Foundation + CoreGraphics**，不 import AVFoundation /
//  CoreVideo / SwiftUI。相机缓冲通过裸指针传进来。
//  这样它能在 macOS 上直接用合成图像跑回归测试 ——
//  格子划分、越界裁剪、通道顺序这三件事都错不起（BGR 和 RGB 写反，
//  整套颜色会红蓝颠倒，肉眼看还挺像"偏色"而不是"写反了"）。
//

import CoreGraphics
import Foundation

/// 0…1 的 RGB。
struct RGBColor: Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    /// 转成 `#RRGGBB`。
    var hex: String {
        func channel(_ value: Double) -> Int {
            Int((max(0, min(1, value)) * 255).rounded())
        }
        return String(format: "#%02X%02X%02X", channel(r), channel(g), channel(b))
    }
}

enum ColorGridSampler {

    // MARK: - 格子划分

    /// 把一块归一化矩形均分成 `rows × columns` 个采样格。
    ///
    /// - Parameter inset: 每格往里收多少（占格宽/格高的比例）。
    ///   必须收一点：颜料盒的格子之间有塑料隔断，采到隔断颜色会整体偏灰。
    ///   默认 0.22 是"只取格子中间那块颜料"的意思。
    /// - Returns: 行优先（先第一行从左到右，再第二行）的矩形数组，共 rows×columns 个。
    static func cellRects(
        grid: CGRect,
        rows: Int,
        columns: Int,
        inset: Double = 0.22
    ) -> [CGRect] {
        guard rows > 0, columns > 0 else { return [] }
        let cellWidth = grid.width / Double(columns)
        let cellHeight = grid.height / Double(rows)
        let clampedInset = max(0, min(0.49, inset))
        let insetX = cellWidth * clampedInset
        let insetY = cellHeight * clampedInset

        var rects: [CGRect] = []
        rects.reserveCapacity(rows * columns)
        for row in 0..<rows {
            for column in 0..<columns {
                rects.append(CGRect(
                    x: grid.minX + Double(column) * cellWidth + insetX,
                    y: grid.minY + Double(row) * cellHeight + insetY,
                    width: max(0, cellWidth - insetX * 2),
                    height: max(0, cellHeight - insetY * 2)
                ))
            }
        }
        return rects
    }

    // MARK: - 取色

    /// 从一块 **BGRA** 像素缓冲里取某区域的平均色。
    ///
    /// - Parameters:
    ///   - bgra: 缓冲首地址。
    ///   - bytesPerRow: 每行字节数（**不等于** width*4，必须用系统给的值）。
    ///   - width/height: 像素尺寸。
    ///   - rect: **归一化**坐标（0…1），会自动裁进画面里。
    ///   - step: 采样步长。取色不需要每个像素都算，步长能省一个数量级的开销。
    /// - Returns: 平均色；区域完全在画面外时返回 nil。
    ///
    /// ⚠️ 通道顺序是 **B、G、R、A**（`kCVPixelFormatType_32BGRA`）。
    ///    写反了会红蓝颠倒，而且看起来很像"颜色偏了"而不是"写反了"，
    ///    所以测试里专门钉了这一点。
    static func averageColor(
        bgra: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        width: Int,
        height: Int,
        rect: CGRect,
        step: Int = 1
    ) -> RGBColor? {
        guard width > 0, height > 0, bytesPerRow > 0 else { return nil }

        // 归一化 → 像素，并裁进画面
        let minX = max(0, Int((rect.minX * Double(width)).rounded(.down)))
        let maxX = min(width - 1, Int((rect.maxX * Double(width)).rounded(.up)) - 1)
        let minY = max(0, Int((rect.minY * Double(height)).rounded(.down)))
        let maxY = min(height - 1, Int((rect.maxY * Double(height)).rounded(.up)) - 1)
        guard minX <= maxX, minY <= maxY else { return nil }

        let stride = max(1, step)
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var count = 0.0

        var y = minY
        while y <= maxY {
            let rowStart = y * bytesPerRow
            var x = minX
            while x <= maxX {
                let offset = rowStart + x * 4
                // BGRA
                sumB += Double(bgra[offset])
                sumG += Double(bgra[offset + 1])
                sumR += Double(bgra[offset + 2])
                count += 1
                x += stride
            }
            y += stride
        }

        guard count > 0 else { return nil }
        return RGBColor(r: sumR / count / 255.0, g: sumG / count / 255.0, b: sumB / count / 255.0)
    }

    /// 把整盒采一遍。
    ///
    /// - Returns: 行优先的十六进制色值数组，长度 = rows × columns。
    ///   某个格子完全落在画面外时该位置为 nil（界面会留空，不是填黑）。
    static func sampleGrid(
        bgra: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        width: Int,
        height: Int,
        grid: CGRect,
        rows: Int,
        columns: Int,
        inset: Double = 0.22
    ) -> [String?] {
        sampleGridColors(
            bgra: bgra, bytesPerRow: bytesPerRow,
            width: width, height: height,
            grid: grid, rows: rows, columns: columns, inset: inset
        ).map { $0?.hex }
    }

    /// 同上，但返回 RGB 而不是十六进制。
    ///
    /// 实时预览要做时域平滑（新值 = 旧值×0.5 + 新采样×0.5），
    /// 否则每秒刷新几次的马赛克会一直在抖。平滑只能在 RGB 上做 ——
    /// 拿十六进制字符串做插值是没有意义的。
    static func sampleGridColors(
        bgra: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        width: Int,
        height: Int,
        grid: CGRect,
        rows: Int,
        columns: Int,
        inset: Double = 0.22
    ) -> [RGBColor?] {
        let rects = cellRects(grid: grid, rows: rows, columns: columns, inset: inset)
        // 每个格子取十来行就够了，再多只是白烧 CPU。
        let step = max(1, min(width, height) / 240)
        return rects.map { rect in
            averageColor(
                bgra: bgra, bytesPerRow: bytesPerRow,
                width: width, height: height,
                rect: rect, step: step
            )
        }
    }

    /// 时域平滑：让实时马赛克别抖。
    /// - Parameter factor: 新采样占的比重。0.45 表示"跟上一帧混一下"。
    static func blend(previous: RGBColor?, next: RGBColor?, factor: Double = 0.45) -> RGBColor? {
        guard let next else { return previous }
        guard let previous else { return next }
        let f = max(0, min(1, factor))
        return RGBColor(
            r: previous.r * (1 - f) + next.r * f,
            g: previous.g * (1 - f) + next.g * f,
            b: previous.b * (1 - f) + next.b * f
        )
    }

    // MARK: - 画面摆放

    /// 缓冲画面在视图里实际占的位置。
    ///
    /// 预览层按 `videoGravity` 摆放画面，所以画在 SwiftUI 上的格子线必须用
    /// **同一套算法**算出来，否则线画在一处、取样在另一处，用户看到的
    /// "实时马赛克"就跟实际保存的色对不上。
    ///
    /// - Parameter fill: `.resizeAspectFill` 传 true（铺满、裁掉多余），
    ///   `.resizeAspect` 传 false（完整显示、留黑边）。
    static func displayRect(
        bufferSize: CGSize,
        in viewSize: CGSize,
        fill: Bool
    ) -> CGRect {
        guard bufferSize.width > 0, bufferSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return .zero }

        let scaleX = viewSize.width / bufferSize.width
        let scaleY = viewSize.height / bufferSize.height
        let scale = fill ? max(scaleX, scaleY) : min(scaleX, scaleY)

        let drawn = CGSize(width: bufferSize.width * scale, height: bufferSize.height * scale)
        return CGRect(
            x: (viewSize.width - drawn.width) / 2,
            y: (viewSize.height - drawn.height) / 2,
            width: drawn.width,
            height: drawn.height
        )
    }

    /// 归一化坐标 → 视图坐标。给画格子线用。
    static func viewPoint(_ normalized: CGPoint, displayRect: CGRect) -> CGPoint {
        CGPoint(
            x: displayRect.minX + normalized.x * displayRect.width,
            y: displayRect.minY + normalized.y * displayRect.height
        )
    }
}
