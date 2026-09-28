//
//  TextbookDownloadPlan.swift
//  ArtAssist — 美术生的工具箱
//
//  下载进度的算法，以及每页的状态机。
//
//  ── 为什么单独拎出来 ─────────────────────────────────────────
//  "还剩多久下完"和"这次到底成功了几页"是用户唯一会盯着看的两件事，
//  算错了立刻就看得出来（进度条卡住、声称下完其实缺页）。
//  而它本身只是整数运算 —— 完全可以脱离网络和文件系统测。
//
//  原 Python 脚本用 `(completed / total) * 100` 算进度，
//  失败页也算进 completed —— 于是"100% 完成"里可能混着 30 页失败。
//  这个文件把"下载成功"和"尝试过"严格分开。
//

import Foundation

/// 一页的下载状态。
enum PageDownloadState: String, CaseIterable, Sendable {
    /// 还没下（或还没试过）。
    case pending
    /// 正在下。
    case downloading
    /// 下好了，本地有文件。
    case done
    /// 试过但失败了，可以重试。
    case failed

    var displayName: String {
        switch self {
        case .pending: return "待下载"
        case .downloading: return "下载中"
        case .done: return "已完成"
        case .failed: return "失败"
        }
    }

    var symbolName: String {
        switch self {
        case .pending: return "circle.dashed"
        case .downloading: return "arrow.down.circle"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

/// 一整本的下载统计。
struct DownloadStats: Equatable, Sendable {
    var done: Int
    var failed: Int
    var downloading: Int
    var pending: Int

    var total: Int { done + failed + downloading + pending }

    /// 完成比例。
    ///
    /// ⚠️ 分母是**总页数**，分子只有 `done`。
    ///    失败的页不算完成 —— 这是原脚本算错的地方。
    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(done) / Double(total)
    }

    var percentText: String {
        String(format: "%.0f%%", fraction * 100)
    }

    /// 全部下完（没有待下、没有在下的、也没有失败的）。
    var isComplete: Bool {
        total > 0 && done == total
    }

    /// 有没有东西可下。
    var hasWork: Bool {
        pending > 0 || failed > 0 || downloading > 0
    }

    /// 现在能不能开始/继续。
    var canStart: Bool {
        pending > 0 || failed > 0
    }

    /// 是否正在跑。
    var isRunning: Bool { downloading > 0 }

    var summary: String {
        if total == 0 { return "没有可下载的页" }
        if isComplete { return "\(done) 页已全部下载" }

        var parts = ["\(done)/\(total)"]
        if failed > 0 { parts.append("\(failed) 页失败") }
        if downloading > 0 { parts.append("\(downloading) 页下载中") }
        if pending > 0 { parts.append("\(pending) 页待下载") }
        return parts.joined(separator: " · ")
    }
}

/// 文件大小的显示。
enum TextbookFormat {

    /// 字节 → "12.3 MB"。
    static func bytes(_ count: Int64) -> String {
        if count <= 0 { return "0 B" }
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(count)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 {
            return "\(Int(value)) B"
        }
        return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[index])
    }

    /// 秒数 → "约 1 分 20 秒"。用于下载剩余时间。
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        if seconds < 60 { return "约 \(Int(seconds.rounded())) 秒" }
        if seconds < 3600 {
            let minutes = Int(seconds / 60)
            let rest = Int(seconds.truncatingRemainder(dividingBy: 60))
            return rest == 0 ? "约 \(minutes) 分" : "约 \(minutes) 分 \(rest) 秒"
        }
        let hours = Int(seconds / 3600)
        let minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
        return "约 \(hours) 小时 \(minutes) 分"
    }
}

/// 根据已下载的字节与耗时估算剩余时间。
///
/// 单独拎出来是因为它最容易写得"看起来对但一直跳"：
/// 必须用**平均速度**而不是瞬时速度，否则数字会疯跳。
struct DownloadEta {
    private(set) var startedAt: Date?
    private(set) var bytesAtStart: Int64 = 0
    private(set) var latestBytes: Int64 = 0

    mutating func begin(bytesAlreadyDone: Int64, now: Date = .now) {
        startedAt = now
        bytesAtStart = bytesAlreadyDone
        latestBytes = bytesAlreadyDone
    }

    mutating func update(bytes: Int64) {
        latestBytes = bytes
    }

    /// 需要补的字节数（用于估时）。
    func estimatedRemainingSeconds(remainingBytes: Int64, now: Date = .now) -> TimeInterval? {
        guard let startedAt else { return nil }
        let elapsed = now.timeIntervalSince(startedAt)
        let transferred = latestBytes - bytesAtStart
        // 前 2 秒或样本太少时不报 —— 不然一开始会显示一个荒唐的数字
        guard elapsed >= 2, transferred > 0, remainingBytes > 0 else { return nil }
        let bytesPerSecond = Double(transferred) / elapsed
        guard bytesPerSecond > 0 else { return nil }
        return Double(remainingBytes) / bytesPerSecond
    }
}
