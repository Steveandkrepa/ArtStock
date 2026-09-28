//
//  NotificationService.swift
//  ArtAssist — 美术生的工具箱
//
//  颜料湿润计时器的本地提醒。
//
//  ── 为什么只能是"本地"通知 ────────────────────────────────────
//  远程推送需要 aps-environment entitlement，免费 Apple ID 签不出来，
//  在 SideStore 自签路线上不可用。
//  但本地通知（UNUserNotificationCenter）**不需要任何 entitlement**，
//  只需要运行时向用户请求授权 —— 而且对本功能本来就够：
//  补水提醒的依据（湿度 + 开始时刻）在**开始计时那一刻就已经全部拿到**，
//  不需要服务器事后推送。
//
//  ── 为什么用日历触发器而不是时间间隔触发器 ────────────────────
//  UNTimeIntervalNotificationTrigger 从"调度那一刻"开始计时，
//  而我们要的是"从会话开始时刻起的绝对时间点"。用
//  UNCalendarNotificationTrigger 按绝对日期匹配，语义才正确，
//  也不会因为后台调度延迟而整体偏移。
//

import Foundation
import UserNotifications

@MainActor
enum NotificationService {

    /// 通知标识前缀。用它精确取消某次会话的提醒，不影响别的通知。
    private static let identifierPrefix = "artstock.wetness."

    private static var center: UNUserNotificationCenter { .current() }

    // MARK: - 授权

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// 确保有授权；没有就请求一次。
    @discardableResult
    static func ensureAuthorized() async -> Bool {
        switch await authorizationStatus() {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - 调度

    /// 为一次会话排定补水提醒。
    ///
    /// 排两条：
    ///   1. 提前 10 分钟预警 —— 让用户有时间收拾，而不是被突然打断
    ///   2. 到点正式提醒 —— 该喷水了
    ///
    /// - Returns: 是否成功排定。false 通常是没授权，或时间点已经过去。
    @discardableResult
    static func scheduleReminder(for session: WetnessSession) async -> Bool {
        guard WetnessPreferences.notificationsEnabled else { return false }

        let identifier = identifierPrefix + sessionIdentifier(session)
        cancel(identifier: identifier)

        guard await ensureAuthorized() else { return false }

        let now = Date.now
        guard session.predictedRemistAt > now else { return false }

        let systemName = session.paintSystem.displayName
        let closureName = session.closure.displayName

        // ── 1) 提前预警 ──
        let preWarnAt = session.predictedRemistAt.addingTimeInterval(-10 * 60)
        if preWarnAt > now {
            let content = UNMutableNotificationContent()
            content.title = "快该给颜料补水了"
            content.body = "约 10 分钟后到建议补水时间（\(systemName) · \(closureName)）。"
            content.sound = .default
            content.interruptionLevel = .active
            content.userInfo = ["sessionID": sessionIdentifier(session), "kind": "prewarn"]
            await add(content: content, identifier: identifier + ".prewarn", fireAt: preWarnAt)
        }

        // ── 2) 正式提醒 ──
        let content = UNMutableNotificationContent()
        content.title = "该给颜料补水了"

        let elapsed = session.predictedRemistAt.timeIntervalSince(session.startedAt)
        var body = "\(systemName) · \(closureName)，已过 \(Fmt.duration(elapsed))"
            + "（\(Fmt.number(session.temperatureC, maximumFractionDigits: 1))℃ / "
            + "\(Fmt.number(session.relativeHumidity, maximumFractionDigits: 0))% 湿度）"

        if session.spraysPerRemist > 0 {
            body += "。建议喷 \(session.spraysPerRemist) 下"
        } else {
            body += "。还没标定「喷一下能维持多久」，暂时只给时间提醒"
        }

        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["sessionID": sessionIdentifier(session), "kind": "remist"]

        await add(content: content, identifier: identifier + ".remist", fireAt: session.predictedRemistAt)
        return true
    }

    /// 取消某次会话的全部提醒。
    static func cancelReminder(for session: WetnessSession) {
        cancel(identifier: identifierPrefix + sessionIdentifier(session))
    }

    private static func cancel(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [
            identifier + ".prewarn", identifier + ".remist"
        ])
        center.removeDeliveredNotifications(withIdentifiers: [
            identifier + ".prewarn", identifier + ".remist"
        ])
    }

    /// 取消全部湿润计时器提醒。
    static func cancelAll() async {
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        )
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(
            withIdentifiers: delivered.map(\.request.identifier).filter { $0.hasPrefix(identifierPrefix) }
        )
    }

    /// 当前排队中的湿润计时器提醒条数（设置页展示用）。
    static func pendingCount() async -> Int {
        let pending = await center.pendingNotificationRequests()
        return pending.filter { $0.identifier.hasPrefix(identifierPrefix) }.count
    }

    /// 发一条测试通知，让用户在设置里确认提醒真能弹出来。
    @discardableResult
    static func sendTestNotification() async -> Bool {
        guard await ensureAuthorized() else { return false }

        let content = UNMutableNotificationContent()
        content.title = "测试提醒"
        content.body = "如果你看到这一条，说明颜料补水提醒可以正常送达。"
        content.sound = .default

        await add(content: content,
                  identifier: identifierPrefix + "test",
                  fireAt: Date.now.addingTimeInterval(3))
        return true
    }

    // MARK: - 内部

    private static func add(content: UNMutableNotificationContent, identifier: String, fireAt: Date) async {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireAt
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await center.add(request)
    }

    private static func sessionIdentifier(_ session: WetnessSession) -> String {
        // persistentModelID 是 SwiftData 给的稳定标识；还没入库时退回时间戳。
        let token = String(describing: session.persistentModelID)
        return token.isEmpty ? String(session.startedAt.timeIntervalSince1970) : token
    }
}

// MARK: - 前台展示

/// 让通知在 App 处于前台时也能弹出横幅。
///
/// 默认情况下 iOS 在前台**不显示**通知、直接静默丢弃 ——
/// 而用户很可能正开着这个 App 等提醒，那样就完全看不到，体验会很怪。
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationPresenter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
