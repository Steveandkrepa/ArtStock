//
//  ImageProcessing.swift
//  ArtAssist — 美术生的工具箱
//
//  照片压缩。SwiftData 的 externalStorage 会把大图写到磁盘文件，
//  但一张 12MP 的原图仍然是几 MB，几百条材料就是 GB 级占用。
//  存之前统一压到长边 1024，肉眼在 iPad 上基本看不出差别。
//

import UIKit

enum ImageProcessing {

    /// 把任意图片数据压成长边不超过 `maxDimension` 的 JPEG。
    /// - Returns: 压缩后的数据；输入无法解码时返回 nil。
    static func downscaledJPEGData(
        from data: Data,
        maxDimension: CGFloat = 1024,
        quality: CGFloat = 0.8
    ) -> Data? {
        guard let image = UIImage(data: data) else { return nil }

        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension else {
            // 已经足够小，只做一次重编码丢掉多余元数据。
            return image.jpegData(compressionQuality: quality) ?? data
        }

        let scale = maxDimension / longestSide
        let targetSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
