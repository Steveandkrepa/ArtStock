//
//  TextbookLibrary.swift
//  ArtAssist — 美术生的工具箱
//
//  SwiftData 桥接：教材入库、页列表同步、进度记录。
//
//  纯逻辑（解析、路径、进度）都在别的文件里且有测试；
//  这里只做"把解析结果写进数据库"和"从数据库读出来"。
//

import Foundation
import SwiftData

enum TextbookLibrary {

    // MARK: - 读

    static func allBooks(in context: ModelContext) -> [Textbook] {
        let descriptor = FetchDescriptor<Textbook>(
            sortBy: [SortDescriptor(\Textbook.addedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    static func book(remoteID: Int, in context: ModelContext) -> Textbook? {
        var descriptor = FetchDescriptor<Textbook>(
            predicate: #Predicate<Textbook> { $0.remoteID == remoteID }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - 入库

    /// 把搜索到的一本书加进"我的教材"。已存在就返回已有的那条。
    @discardableResult
    static func add(_ summary: TextbookSummary, in context: ModelContext) -> Textbook {
        if let existing = book(remoteID: summary.remoteID, in: context) {
            // 顺手更新名字与热度 —— 厂家可能改过
            if !summary.name.isEmpty, existing.name != summary.name {
                existing.name = summary.name
            }
            existing.viewCount = summary.viewCount
            if let cover = summary.coverURL, !cover.isEmpty, existing.coverURL != cover {
                existing.coverURL = cover
            }
            try? context.save()
            return existing
        }

        let created = Textbook(
            remoteID: summary.remoteID,
            name: summary.displayName,
            coverURL: summary.coverURL ?? "",
            viewCount: summary.viewCount
        )
        context.insert(created)
        try? context.save()
        return created
    }

    /// 把取到的页列表同步进这本书。
    ///
    /// 行为要点：
    ///   · **已经下好的页不动**（不能因为重取一次列表就把本地文件标记成待下载）
    ///   · 接口里消失的页要删掉；新增的页插进来
    ///   · 页的远程地址变了的话，已下载的本地文件仍然有效，只是记下新地址
    @discardableResult
    static func syncPages(
        _ pages: [TextbookPageInfo],
        into textbook: Textbook,
        in context: ModelContext
    ) -> (added: Int, removed: Int) {
        var existing = Dictionary(
            textbook.pages.map { ($0.pageNumber, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var added = 0
        var removed = 0
        let incomingPages = Set(pages.map(\.pageNumber))

        // 删掉接口里已经没有的页
        for page in textbook.pages where !incomingPages.contains(page.pageNumber) {
            context.delete(page)
            existing[page.pageNumber] = nil
            removed += 1
        }

        for info in pages {
            if let page = existing[info.pageNumber] {
                // 地址变了就更新地址，但**不动 state / localRelativePath** ——
                // 本地文件还是好的，没必要重下。
                if page.remoteURL != info.remoteURL {
                    page.remoteURL = info.remoteURL
                    page.updatedAt = .now
                }
                // 之前标记完成但文件其实没了 → 退回待下载
                if page.state == .done,
                   !page.localFileExists(bookName: textbook.name, remoteID: textbook.remoteID) {
                    page.state = .pending
                    page.localRelativePath = ""
                    page.byteCount = 0
                    page.updatedAt = .now
                }
            } else {
                let created = TextbookPage(pageNumber: info.pageNumber, remoteURL: info.remoteURL)
                created.textbook = textbook
                context.insert(created)
                added += 1
            }
        }

        textbook.pageCount = pages.count
        textbook.lastSyncedAt = .now
        if textbook.lastReadPage > pages.count {
            textbook.lastReadPage = pages.count
        }
        try? context.save()
        return (added, removed)
    }

    // MARK: - 进度

    static func recordReading(_ page: Int, of textbook: Textbook, in context: ModelContext) {
        let clamped = max(0, min(page, max(1, textbook.pageCount)))
        guard clamped != textbook.lastReadPage else { return }
        textbook.lastReadPage = clamped
        textbook.lastOpenedAt = .now
        try? context.save()
    }

    static func markOpened(_ textbook: Textbook, in context: ModelContext) {
        textbook.lastOpenedAt = .now
        try? context.save()
    }

    // MARK: - 删除

    /// 只删本地文件，保留书与进度。
    ///
    /// - Returns: 真正删掉的文件数。调用方要用它来给用户一句准确的反馈 ——
    ///   "删了 12 个文件"和"本来就没有本地文件"是两种不同的事实，
    ///   含糊地说一句"已删除"会让用户以为删掉了其实不存在的东西。
    @discardableResult
    static func removeLocalFiles(of textbook: Textbook, in context: ModelContext) -> Int {
        TextbookStorage.removeBookFiles(remoteID: textbook.remoteID, name: textbook.name)
        var removed = 0
        for page in textbook.pages {
            if page.state == .done || !page.localRelativePath.isEmpty { removed += 1 }
            page.state = .pending
            page.localRelativePath = ""
            page.byteCount = 0
            page.failureReason = ""
            page.updatedAt = .now
        }
        try? context.save()
        return removed
    }

    /// 删掉指定的几页的本地文件。返回真正删掉文件数。
    ///
    /// 用于下载管理里"删掉选中的 N 页"。
    /// 只动本地文件，**页记录保留** —— 所以它退化成"待下载"，
    /// 以后还能重新下，不会破坏书的完整性。
    @discardableResult
    static func removeLocalFiles(
        of textbook: Textbook,
        pages: [TextbookPage],
        in context: ModelContext
    ) -> Int {
        var removed = 0
        for page in pages {
            if let url = page.localFileURL(bookName: textbook.name, remoteID: textbook.remoteID),
               FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                removed += 1
            }
            page.state = .pending
            page.localRelativePath = ""
            page.byteCount = 0
            page.failureReason = ""
            page.updatedAt = .now
        }
        try? context.save()
        return removed
    }

    /// 所有教材在本地占了多少。
    static func totalLocalBytes(books: [Textbook]) -> Int64 {
        books.reduce(Int64(0)) { $0 + $1.localBytes }
    }

    /// 所有教材的批注占了多少。
    static func totalDrawingBytes(books: [Textbook]) -> Int64 {
        books.reduce(Int64(0)) {
            $0 + TextbookStorage.drawingByteCount(remoteID: $1.remoteID, name: $1.name)
        }
    }

    /// 整本删掉（含本地文件）。
    static func remove(_ textbook: Textbook, in context: ModelContext) {
        TextbookStorage.removeBookFiles(remoteID: textbook.remoteID, name: textbook.name)
        context.delete(textbook)
        try? context.save()
    }

    /// 把"本地文件其实已经不在"的页统一退回待下载。
    ///
    /// 在打开教材详情/阅读器时调一次。不这么做的话，用户会看到
    /// "100% 已下载"但翻页全是空白 —— 那是最让人恼火的一种状态。
    @discardableResult
    static func reconcileLocalFiles(of textbook: Textbook, in context: ModelContext) -> Int {
        var changed = 0
        for page in textbook.pages where page.state == .done {
            if !page.localFileExists(bookName: textbook.name, remoteID: textbook.remoteID) {
                page.state = .pending
                page.localRelativePath = ""
                page.byteCount = 0
                page.updatedAt = .now
                changed += 1
            }
        }
        if changed > 0 { try? context.save() }
        return changed
    }
}
