//
//  ReaderGeometry.swift
//  ArtAssist — 美术生的工具箱
//
//  阅读器"放大之后能拖到哪儿"的算术。
//
//  ── 为什么单独拎出来 ─────────────────────────────────────────
//  这段算术最容易错，而错了的后果用户一眼就能看出来：
//    · 算出负数 → 拖动方向反过来，越拖越偏
//    · 边界太小 → 拖不动，用户抱怨"放大只能看中间那一块"
//    · 边界太大 → 能拖到页面外面，满屏空白，还以为图没了
//  所以把它做成纯函数，离线把所有边界情况钉住（见 TextbookTests）。
//

import CoreGraphics

enum ReaderGeometry {

    /// 内容按 aspect-fit 放进容器之后占多大。
    ///
    /// 阅读器里的页面图是 `aspectRatio(contentMode: .fit)` 的 ——
    /// 容器里会有留白。算拖动边界必须用**图片实际占的尺寸**，
    /// 用容器尺寸会把边界算大，于是能拖进留白区。
    static func fitted(content: CGSize, in container: CGSize) -> CGSize {
        guard content.width > 0, content.height > 0,
              container.width > 0, container.height > 0 else {
            return container
        }
        let scale = min(container.width / content.width,
                        container.height / content.height)
        return CGSize(width: content.width * scale,
                      height: content.height * scale)
    }

    /// 放大之后，单边最多能拖多远（相对居中位置）。
    ///
    /// 内容比容器小的时候是 **0**，不是负数 —— 这一点很关键：
    /// 负数会让拖动反向，表现就是"越拖越偏"。
    static func maxPan(content: CGSize, container: CGSize, zoom: CGFloat) -> CGSize {
        CGSize(
            width: max(0, (content.width * zoom - container.width) / 2),
            height: max(0, (content.height * zoom - container.height) / 2)
        )
    }

    /// 把拖动位移夹在边界内。
    static func clamp(_ offset: CGSize,
                      content: CGSize,
                      container: CGSize,
                      zoom: CGFloat) -> CGSize {
        let limit = maxPan(content: content, container: container, zoom: zoom)
        return CGSize(
            width: min(limit.width, max(-limit.width, offset.width)),
            height: min(limit.height, max(-limit.height, offset.height))
        )
    }

    /// 缩放落定时的取值。
    ///
    /// 缩到 1 附近就吸附回 1：停在 1.03 这种状态最难受 ——
    /// 看着没放大，但翻页和单点分区全都失效了（它们都以"没放大"为前提）。
    static func settledZoom(_ zoom: CGFloat, threshold: CGFloat = 1.15) -> CGFloat {
        if zoom < threshold { return 1 }
        return min(maxZoom, max(1, zoom))
    }

    /// 放大上限。再大就只剩像素块了，对看教材没有意义。
    static let maxZoom: CGFloat = 5
}
