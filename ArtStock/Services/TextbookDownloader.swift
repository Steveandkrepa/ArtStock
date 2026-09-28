//
//  TextbookDownloader.swift
//  ArtAssist — 美术生的工具箱
//
//  教材原图的下载器：受限并发、断点续传、每页状态、失败重试。
//
//  ── 对比原 Python 脚本 ───────────────────────────────────────
//  原脚本：
//      with ThreadPoolExecutor(max_workers=8) as executor:
//          for future in as_completed(futures):
//              console.print(f"✅ 第 {p_num:03d} 页下载成功 ({completed}/{total})")
//
//  在终端里这样没问题，搬到 App 里就有四个毛病：
//    · **8 线程全速冲**：iPad 上和别的网络活动抢带宽，而且一次开 8 个连接
//      很容易被 CDN 限速甚至掐断。这里降到 4，并留出重试余量。
//    · **失败只打印一行**：用户看不到"哪几页失败了"，更没法只重试失败的。
//      这里每一页都有状态，失败页可以单独重试。
//    · **进度把失败算成完成**：见 `DownloadStats` 的说明。
//    · **中断就全丢**：App 一被系统挂起，那些 future 全没了，
//      下次只能从头再来。这里把每页的完成状态写进数据库，
//      下次打开只下缺的那部分。
//
//  ── 关于"后台下载" ───────────────────────────────────────────
//  这里用的是**前台会话 + 断点续传**，不是 `URLSessionConfiguration.background`。
//  原因是我没法在真机上验证后台会话那套（delegate 生命周期、被系统回收后
//  恢复、`handleEventsForBackgroundURLSession` 的 AppDelegate 接线），
//  而它的失败方式很隐蔽（看起来在跑，其实早停了）。
//  前台方案的行为是可预期的：
//    · 下载期间禁止息屏（`isIdleTimerDisabled`）
//    · 切后台时申请一小段额外时间（`beginBackgroundTask`）
//    · 被系统挂起后任务停在磁盘上的状态里，回来点「继续」即可续传
//  真机上如果需要"锁屏也继续下"，那是下一步换成后台会话的事。
//

import Foundation
import Observation
import SwiftData
import UIKit

/// 一个下载任务需要的最小信息。
///
/// ⚠️ 刻意**不含 SwiftData 模型**。
/// `@Model` 类型不是 `Sendable`，把 `TextbookPage` 丢进并发子任务：
///   · Swift 5 下只是一个 warning，但那是真的不安全
///     （模型属性在别的线程读、主线程写）
///   · Swift 6 下直接是编译错误
///   · 更实际的问题是：子任务里读模型会隐式跳回主线程，
///     于是"4 路并发"变成"串行下载"，界面还会被写盘卡住
/// 所以只传页码和地址，模型更新一律回到主线程做。
struct TextbookPageJob: Sendable {
    let pageNumber: Int
    let remoteURL: String
    /// 页图目录（URL 是 Sendable 的）。
    let directory: URL?
}

@MainActor
@Observable
final class TextbookDownloader {

    /// 同时下几页。原脚本 8，这里 4 —— 见文件头的说明。
    static let maxConcurrent = 4
    /// 单页最多重试几次。
    static let maxRetryPerPage = 3

    private(set) var isRunning = false
    private(set) var currentBookName: String = ""
    /// 最近一次操作的说明，给界面弹提示。
    private(set) var lastMessage: String?

    @ObservationIgnored private let client = DXArtClient()
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var eta = DownloadEta()
    /// 本次运行开始前本地已有的字节数（用来算速度）。
    @ObservationIgnored private var bytesAtStart: Int64 = 0
    @ObservationIgnored private var bytesNow: Int64 = 0
    /// 每一页已经试过几次。
    @ObservationIgnored private var attempts: [Int: Int] = [:]

    /// 估算的剩余时间文案。
    var etaText: String {
        guard isRunning, let remaining = remainingBytesEstimate() else { return "" }
        guard let seconds = eta.estimatedRemainingSeconds(remainingBytes: remaining) else { return "" }
        return TextbookFormat.duration(seconds)
    }

    /// 已下字节（本次运行内累计，含之前已下的）。
    var transferredBytes: Int64 { bytesNow }

    private func remainingBytesEstimate() -> Int64? {
        // 用"已下页的平均大小 × 剩余页数"估。没有样本就不估。
        guard let average = averagePageBytes, average > 0, pendingPageCount > 0 else { return nil }
        return average * Int64(pendingPageCount)
    }

    @ObservationIgnored private var averagePageBytes: Int64?
    @ObservationIgnored private var pendingPageCount: Int = 0

    // MARK: - 启停

    /// 开始（或继续）下载一整本。
    ///
    /// - Parameter onlyFailed: 只重试失败的页（用户点了「重试失败的 12 页」）。
    func start(
        textbook: Textbook,
        context: ModelContext,
        onlyFailed: Bool = false
    ) {
        guard !isRunning else { return }

        let pages = textbook.orderedPages
        let targets = onlyFailed
            ? pages.filter { $0.state == .failed }
            : pages.filter { $0.state != .done }

        guard !targets.isEmpty else {
            lastMessage = "没有需要下载的页。"
            return
        }

        // 目标页统一先打回"待下载"（失败页不变，保留失败原因直到真正重试）
        for page in targets where page.state != .failed {
            page.state = .pending
            page.failureReason = ""
        }
        try? context.save()

        attempts.removeAll()
        isRunning = true
        currentBookName = textbook.name
        pendingPageCount = targets.count
        bytesAtStart = textbook.localBytes
        bytesNow = bytesAtStart
        eta.begin(bytesAlreadyDone: bytesAtStart)

        // 已下页的平均大小，用于估时
        let done = pages.filter { $0.state == .done && $0.byteCount > 0 }
        averagePageBytes = done.isEmpty
            ? nil
            : done.reduce(Int64(0)) { $0 + Int64($1.byteCount) } / Int64(done.count)

        beginBackgroundTask()
        UIApplication.shared.isIdleTimerDisabled = true

        runTask = Task { [weak self] in
            await self?.run(
                bookName: textbook.name,
                remoteID: textbook.remoteID,
                statsOwner: textbook,
                pages: targets,
                context: context
            )
        }
    }

    /// 停止。已经下好的页保留，未完成的停在"待下载"。
    func stop(context: ModelContext) {
        runTask?.cancel()
        runTask = nil
        finish(context: context, message: "已暂停。下次点继续会从缺的页接着下。")
    }

    /// 主循环。**在主线程上跑调度**，真正的下载与写盘在子任务里。
    private func run(
        bookName: String,
        remoteID: Int,
        statsOwner: Textbook,
        pages: [TextbookPage],
        context: ModelContext
    ) async {
        // 目录只算一次
        let directory = TextbookStorage.pagesDirectory(remoteID: remoteID, name: bookName)

        var queue = pages
        var failures: [String] = []

        while !queue.isEmpty, !Task.isCancelled {
            // 取一小批并发下
            let batch = Array(queue.prefix(Self.maxConcurrent))
            queue.removeFirst(batch.count)

            // 先把这一批要用的**值**取出来，再进并发 —— 模型绝不跨域
            let jobs: [TextbookPageJob] = batch.map { page in
                if page.state != .failed { page.state = .downloading }
                return TextbookPageJob(
                    pageNumber: page.pageNumber,
                    remoteURL: page.remoteURL,
                    directory: directory
                )
            }
            try? context.save()

            let client = self.client
            await withTaskGroup(of: (Int, Result<Int, Error>).self) { group in
                for job in jobs {
                    group.addTask {
                        do {
                            let bytes = try await Self.fetchPage(job, client: client)
                            return (job.pageNumber, .success(bytes))
                        } catch {
                            return (job.pageNumber, .failure(error))
                        }
                    }
                }

                for await (pageNumber, result) in group {
                    if Task.isCancelled { break }
                    guard let page = pages.first(where: { $0.pageNumber == pageNumber }) else { continue }

                    switch result {
                    case .success(let bytes):
                        page.state = .done
                        page.byteCount = bytes
                        page.localRelativePath = TextbookStorage.relativePagePath(page: pageNumber)
                        page.failureReason = ""
                        bytesNow += Int64(bytes)
                        eta.update(bytes: bytesNow)
                    case .failure(let error):
                        let tried = (attempts[pageNumber] ?? 0) + 1
                        attempts[pageNumber] = tried
                        if tried < Self.maxRetryPerPage, !Task.isCancelled {
                            // 放回队尾重试
                            page.state = .pending
                            queue.append(page)
                        } else {
                            page.state = .failed
                            page.failureReason = Self.shortReason(error)
                            failures.append("第 \(pageNumber) 页")
                        }
                    }
                    page.updatedAt = .now
                    // 每页存一次盘：被系统杀掉时进度不会丢
                    try? context.save()
                }
            }

            pendingPageCount = queue.count
        }

        if Task.isCancelled {
            return
        }

        let stats = statsOwner.downloadStats
        if failures.isEmpty {
            finish(context: context, message: "《\(bookName)》下载完成，\(stats.done) 页都在本地了。")
        } else {
            let preview = failures.prefix(5).joined(separator: "、")
            let more = failures.count > 5 ? " 等 \(failures.count) 页" : ""
            finish(context: context, message: "有 \(failures.count) 页没下成功（\(preview)\(more)）。可以在页面列表里点重试。")
        }
    }

    /// 真正的单页下载：取图 + 写盘。
    ///
    /// 标 `nonisolated static` 是**功能性的**，不是为了让编译器安静：
    /// 如果它是 `@MainActor` 实例方法，子任务里的 `await self.fetch(...)`
    /// 会把整个下载过程搬回主线程执行 —— 4 路并发退化成串行，
    /// 每一次写盘还会卡住界面。这里只吃纯值，不碰任何主线程状态。
    private nonisolated static func fetchPage(
        _ job: TextbookPageJob,
        client: DXArtClient
    ) async throws -> Int {
        let data = try await client.imageData(from: job.remoteURL)

        guard let directory = job.directory else {
            throw DXArtError.network("无法定位教材目录")
        }
        guard TextbookStorage.ensureDirectory(directory) else {
            throw DXArtError.network("无法创建教材目录（存储空间不足？）")
        }

        let fileURL = directory.appendingPathComponent(
            TextbookStorage.fileName(forPage: job.pageNumber)
        )
        do {
            // 写临时文件再原子替换：中途被杀不会留下半张图
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw DXArtError.network("写入失败：\(error.localizedDescription)")
        }
        return data.count
    }

    /// 把错误压成一句人话（存进页记录里给用户看）。
    private static func shortReason(_ error: Error) -> String {
        if let artError = error as? DXArtError {
            switch artError {
            case .network(let detail): return detail
            case .badResponse(_, let message): return message
            case .unauthorized: return "登录失效"
            case .empty: return "服务器没有这一页"
            case .decoding(let detail): return detail
            }
        }
        return error.localizedDescription
    }

    private func finish(context: ModelContext, message: String) {
        isRunning = false
        lastMessage = message
        currentBookName = ""
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask()
        try? context.save()
    }

    // MARK: - 只下当前页（阅读时按需缓存）

    /// 阅读时把当前页顺手存下来。
    ///
    /// 这样即使没点「下载整本」，读过一遍之后那些页也已经在本地了 ——
    /// 第二次翻到就是瞬时的，断网也能看。这是原脚本完全做不到的
    /// （它每次都从远程加载）。
    func cachePage(
        _ page: TextbookPage,
        textbook: Textbook,
        context: ModelContext
    ) async {
        guard page.state != .done, page.state != .downloading else { return }
        page.state = .downloading
        let job = TextbookPageJob(
            pageNumber: page.pageNumber,
            remoteURL: page.remoteURL,
            directory: TextbookStorage.pagesDirectory(
                remoteID: textbook.remoteID, name: textbook.name
            )
        )
        do {
            let bytes = try await Self.fetchPage(job, client: client)
            page.state = .done
            page.byteCount = bytes
            page.localRelativePath = TextbookStorage.relativePagePath(page: page.pageNumber)
            page.failureReason = ""
        } catch {
            // 按需缓存失败不打扰用户 —— 页面上会显示远程图，能看到就行
            page.state = .pending
            page.failureReason = ""
        }
        page.updatedAt = .now
        try? context.save()
    }

    // MARK: - 后台时间

    /// 申请一小段后台时间，让用户切出去看一眼别的 App 时下载不立刻停。
    /// 系统给的时间很短（通常 30 秒左右），但比立刻停好。
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "TextbookDownload") { [weak self] in
            // 系统要收回了：干净地结束，把状态留在磁盘上
            Task { @MainActor in
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
