//
//  Textbook.swift
//  ArtAssist — 美术生的工具箱
//
//  教材的书与页。
//
//  ── 为什么要建成表，而不是像原脚本那样"每次重新拉一遍" ───────
//  原 Python 脚本每次运行都要：登录 → 搜索 → 取页 → 再决定干什么。
//  于是有三件事做不到：
//    · 记不住"这本书我读到第几页了"
//    · 记不住"这本书我下过哪些页"（所以无法续传）
//    · 离线时什么都看不到
//
//  建成 SwiftData 记录之后这三件事都是自然的结果。
//
//  ── 存相对路径，不存绝对路径 ─────────────────────────────────
//  `localRelativePath` 存的是 `pages/0007.jpg` 这种相对路径。
//  iOS 沙盒的绝对路径在 App 更新/重装后会变（容器 UUID 会变），
//  存绝对路径的话，升级一次全部本地文件都"找不到了"。
//

import Foundation
import SwiftData

@Model
final class Textbook {

    /// 厂家那边的书 id。唯一。
    @Attribute(.unique) var remoteID: Int

    var name: String
    var coverURL: String
    var viewCount: Int

    /// 一共几页（取过一次之后就知道）。
    var pageCount: Int

    /// 读到第几页（1 起）。0 表示还没开始读。
    var lastReadPage: Int

    var addedAt: Date
    var lastOpenedAt: Date?
    /// 最近一次同步页列表的时间。
    var lastSyncedAt: Date?

    /// 本地的封面文件名（下载到书目录里）。空表示还没缓存。
    var coverFileName: String

    @Relationship(deleteRule: .cascade, inverse: \TextbookPage.textbook)
    var pages: [TextbookPage] = []

    init(
        remoteID: Int,
        name: String,
        coverURL: String = "",
        viewCount: Int = 0,
        pageCount: Int = 0,
        addedAt: Date = .now
    ) {
        self.remoteID = remoteID
        self.name = name
        self.coverURL = coverURL
        self.viewCount = viewCount
        self.pageCount = pageCount
        self.lastReadPage = 0
        self.addedAt = addedAt
        self.coverFileName = ""
    }
}

// MARK: - 派生

extension Textbook {

    /// 按页码排好序的页。
    var orderedPages: [TextbookPage] {
        pages.sorted { $0.pageNumber < $1.pageNumber }
    }

    /// 已经下到本地的页数。
    var downloadedPageCount: Int {
        pages.filter { $0.state == .done }.count
    }

    /// 失败页数。
    var failedPageCount: Int {
        pages.filter { $0.state == .failed }.count
    }

    /// 下载统计。
    var downloadStats: DownloadStats {
        var stats = DownloadStats(done: 0, failed: 0, downloading: 0, pending: 0)
        for page in pages {
            switch page.state {
            case .done: stats.done += 1
            case .failed: stats.failed += 1
            case .downloading: stats.downloading += 1
            case .pending: stats.pending += 1
            }
        }
        return stats
    }

    /// 整本是否已在本地（可以离线读）。
    var isFullyDownloaded: Bool {
        !pages.isEmpty && pages.allSatisfy { $0.state == .done }
    }

    /// 读到哪了，给界面用。
    var readingProgressText: String {
        guard pageCount > 0 else { return "还没取到页数" }
        if lastReadPage <= 0 { return "共 \(pageCount) 页 · 还没开始读" }
        return "读到第 \(lastReadPage) / \(pageCount) 页"
    }

    var readingFraction: Double {
        guard pageCount > 0, lastReadPage > 0 else { return 0 }
        return min(1, Double(lastReadPage) / Double(pageCount))
    }

    /// 本地占用的空间。
    var localBytes: Int64 {
        TextbookStorage.localByteCount(remoteID: remoteID, name: name)
    }

    /// 下一页要读的位置（用于"继续阅读"）。
    var resumePage: Int {
        guard pageCount > 0 else { return 1 }
        if lastReadPage <= 0 { return 1 }
        return min(pageCount, lastReadPage)
    }
}

// MARK: - 页

@Model
final class TextbookPage {

    /// 页码，来自接口的 `pagination`。1 起。
    var pageNumber: Int

    /// 远程图片地址（已去掉查询串）。
    var remoteURL: String

    /// 本地文件相对书目录的路径，例如 `pages/0007.jpg`。
    /// 空表示还没下。
    var localRelativePath: String

    /// `PageDownloadState` 的原始值。
    var stateRaw: String

    /// 已下载的字节数。
    var byteCount: Int

    /// 失败原因（给用户看的一句话）。
    var failureReason: String

    var updatedAt: Date

    var textbook: Textbook?

    init(
        pageNumber: Int,
        remoteURL: String,
        state: PageDownloadState = .pending,
        localRelativePath: String = "",
        byteCount: Int = 0,
        failureReason: String = "",
        updatedAt: Date = .now
    ) {
        self.pageNumber = pageNumber
        self.remoteURL = remoteURL
        self.localRelativePath = localRelativePath
        self.stateRaw = state.rawValue
        self.byteCount = byteCount
        self.failureReason = failureReason
        self.updatedAt = updatedAt
    }
}

// MARK: - 枚举桥接与派生

extension TextbookPage {

    var state: PageDownloadState {
        get { PageDownloadState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }

    /// 本地文件是否真的存在。
    ///
    /// ⚠️ 只看 `state == .done` 是不够的：iOS 可能在存储紧张时清掉
    /// Caches 目录，用户也可能在「文件」App 里删掉（如果暴露了）。
    /// 所以每页都实测一次文件在不在 —— 文件没了就退回"待下载"。
    func localFileURL(bookName: String, remoteID: Int) -> URL? {
        guard !localRelativePath.isEmpty else { return nil }
        guard let directory = TextbookStorage.bookDirectory(remoteID: remoteID, name: bookName) else {
            return nil
        }
        return directory.appendingPathComponent(localRelativePath)
    }

    func localFileExists(bookName: String, remoteID: Int) -> Bool {
        guard let url = localFileURL(bookName: bookName, remoteID: remoteID) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
