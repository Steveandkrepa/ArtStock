//
//  TextbookThumbnailLoader.swift
//  ArtAssist — 美术生的工具箱
//
//  教材页面缩略图加载器。
//
//  ── 为什么需要它（崩溃根因）──────────────────────────────
//  阅读器的「页面列表 / 预览目录」用 LazyVGrid 铺开所有页。原来每格直接
//  `UIImage(contentsOfFile:)` —— 把**整张扫描原图**解进内存。
//  一页是 12MP 左右（~4000×3000），RGBA 解码后单页就 ~48MB；
//  预览目录一屏 ~18 格 ≈ 近 1GB，滚动浏览几百页时内存一路涨，
//  直接被系统 jetsam 杀进程 —— 表现就是「预览目录里翻一翻 App 就崩了」。
//
//  ── 解决办法 ────────────────────────────────────────────
//  1. 用 ImageIO 的 `CGImageSourceCreateThumbnailAtIndex` **只解码小尺寸**：
//     长边 720px（预览格子实际显示 ~144pt，@3x 也才 ~432px，720 留足余量），
//     单张缩略图约 1.5MB，是原图的 1/30。主线程解码一次只有几十毫秒，
//     相比"一次性吃掉上 GB"是数量级的改善。
//  2. 进程级有界 NSCache：滚动回来 / 反复打开预览目录不再重新解码；
//     `totalCostLimit` 把缓存钉在 ~24MB，满时自动淘汰，不会无限涨。
//
//  注意：这里**只**服务缩略图。阅读器正文的单页原图仍走
//  `pageImage` 的 `UIImage(contentsOfFile:)` —— 一次只渲染当前页，
//  没有"多页同渲"的问题，保持原图质量。

import ImageIO
import UIKit

enum TextbookThumbnailLoader {

    /// 缩略图长边上限（像素）。预览格子 ~144pt，@2x/@3x 下 ~288–432px，
    /// 720 是它的 1.5–2 倍余量：保证清晰，又不会把像素量推上去。
    static let maxPixelSize: CGFloat = 720

    /// 进程级有界缓存。`cost` 用近似字节数记账，`totalCostLimit` 兜底，
    /// 不会因为开了一次预览目录就永久占住大块内存。
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 300
        c.totalCostLimit = 24 * 1024 * 1024   // ~24 MB
        return c
    }()

    /// 取某页本地图片的缩略图（带缓存）。
    ///
    /// 返回 nil 表示文件不存在 / 解码失败，调用方按"无图"处理。
    static func thumbnail(at url: URL) -> UIImage? {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return downsample(source: source, key: key)
    }

    /// 取某页**远程**图片的缩略图（异步：下载 → 降采样 → 缓存）。
    ///
    /// 为什么不能直接用 AsyncImage：它会把整张原图下载并**全分辨率解码**，
    /// 预览目录里每格都这么干，内存照样崩。这里下载的是压缩数据
    /// （一页 JPEG 约 2–5MB，逐格下载、随取随弃），ImageIO 只解出 720px，
    /// 内存占用和本地缩略图同级。URLSession.shared 自带 URLCache，
    /// 同一 URL 重复请求命中缓存，不会重复下载。
    ///
    /// 幂等：已缓存的直接返回。
    static func remoteThumbnail(from url: URL) async -> UIImage? {
        let key = url.absoluteString as NSString
        if let hit = cache.object(forKey: key) { return hit }

        guard let (data, _) = try? await URLSession.shared.data(from: url) else {
            return nil
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downsample(source: source, key: key)
    }

    /// 用 ImageIO 从图像源解出**小尺寸**缩略图并写入缓存。
    ///
    /// 关键参数：
    ///   · CreateThumbnailFromImageAlways —— 文件里没有内嵌缩略图时，
    ///     也从原图现解一张（扫描件一般没有内嵌缩略图，必须开）。
    ///   · ThumbnailMaxPixelSize       —— 长边上限，内存从这里省出来。
    ///   · CreateThumbnailWithTransform —— 保留 EXIF 方向，竖版扫描件
    ///     不会横过来。
    ///   · ShouldCacheImmediately      —— 现在就解码，避免之后在
    ///     主线程渲染时才补解码（那正是"滚起来卡顿"的来源之一）。
    private static func downsample(source: CGImageSource, key: NSString) -> UIImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let image = UIImage(cgImage: cgImage)
        // 以近似字节数（RGBA）记账，让 NSCache 能按内存上限正确淘汰。
        let cost = cgImage.width * cgImage.height * 4
        cache.setObject(image, forKey: key, cost: cost)
        return image
    }
}
