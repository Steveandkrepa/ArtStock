//
//  WatchWetnessStore.swift
//  ArtAssist — 美术生的工具箱（Apple Watch 端）
//
//  保湿计时的状态与落盘。
//
//  ── 预测逻辑不是这里写的 ─────────────────────────────────────
//  干燥模型（`DryingModel`）是**同一份源码**编译进手表 target 的，
//  所以手表和 iPad 给出的结论一定一致 —— 不会出现"两边算得不一样"。
//  这里只负责：保存当前这次计时、算剩余时间、到点提醒。
//
//  ── 为什么用 UserDefaults 而不是 SwiftData ────────────────────
//  要存的就是"这一次计时的开始时间和几个参数"，一个 JSON 就够。
//  为它引入 SwiftData 会在手表上多一份模型文件与迁移负担，不划算。
//  （iOS 端用 SwiftData 是因为那边管的是颜料盒/库存这种真数据。）
//

import Foundation
import Observation
import UserNotifications
import WatchKit

/// 一次正在进行的保湿计时。
struct WatchWetnessSession: Codable, Equatable, Sendable {
    /// 开始时间。
    var startedAt: Date
    /// 需要补水的时刻（由干燥模型算出）。
    var remistDeadline: Date
    /// 开始时的环境与参数，界面上要说清"这次是按什么算的"。
    var temperatureC: Double
    var relativeHumidity: Double
    var paintSystemRaw: String
    var closureRaw: String
    /// 是否用了模型预测（false = 用户直接选了固定分钟数）。
    var usedModel: Bool

    var paintSystem: PaintSystem {
        PaintSystem(rawValue: paintSystemRaw) ?? .gouache
    }

    var closure: PaletteClosure {
        PaletteClosure(rawValue: closureRaw) ?? .open
    }
}

@MainActor
@Observable
final class WatchWetnessStore {

    /// 正在进行的计时。nil = 没有。
    private(set) var session: WatchWetnessSession?

    // ── 开始之前的输入 ──
    /// 温度。手表上没有天气，只能手调（数字表冠）。
    var temperatureC: Double = 25
    /// 相对湿度。
    var relativeHumidity: Double = 50
    var paintSystem: PaintSystem = .gouache
    var closure: PaletteClosure = .open
    /// 是否要发提醒。
    var notifyWhenDue = true

    /// 最后一次失败/提示信息（比如通知权限没给）。
    private(set) var note: String?

    private static let sessionKey = "watch.wetness.session"
    private static let settingsKey = "watch.wetness.settings"
    private static let notificationID = "watch.wetness.remist"

    init() {
        restore()
    }

    // MARK: - 预测

    /// 按当前输入算出"还要多久需要补水"。
    ///
    /// 直接调 iOS 端同一个模型 —— 不在这里重复任何物理计算。
    var forecast: DryingForecast {
        DryingModel.forecast(DryingInput(
            temperatureC: temperatureC,
            relativeHumidity: relativeHumidity,
            paintSystem: paintSystem,
            closure: closure,
            // 手表上不做标定（标定要实测一次喷水时长，那是 iPad 上的活），
            // 所以这里永远是模型自带的起点猜测值 —— 界面上会说明这一点。
            calibrationOverride: WetnessPreferences.calibration(for: paintSystem),
            minutesPerSpray: WetnessPreferences.minutesPerSpray,
            startedAt: .now
        ))
    }

    /// 现在的输入下，预计多少分钟后需要补水。
    var predictedMinutes: Int {
        max(1, Int(forecast.remistIntervalMinutes.rounded()))
    }

    /// 当前这次计时还剩多少秒（负数 = 已经过点了）。
    var secondsRemaining: Int? {
        guard let session else { return nil }
        return Int(session.remistDeadline.timeIntervalSinceNow.rounded())
    }

    /// 到点了没。
    var isDue: Bool {
        guard let remaining = secondsRemaining else { return false }
        return remaining <= 0
    }

    // MARK: - 开始 / 结束

    /// 按模型预测开始计时。
    func startUsingModel() {
        let f = forecast
        begin(WatchWetnessSession(
            startedAt: .now,
            remistDeadline: f.remistDeadline,
            temperatureC: temperatureC,
            relativeHumidity: relativeHumidity,
            paintSystemRaw: paintSystem.rawValue,
            closureRaw: closure.rawValue,
            usedModel: true
        ))
    }

    /// 按固定分钟数开始计时（不想管温湿度时的快捷方式）。
    func startFixed(minutes: Int) {
        begin(WatchWetnessSession(
            startedAt: .now,
            remistDeadline: Date.now.addingTimeInterval(Double(minutes) * 60),
            temperatureC: temperatureC,
            relativeHumidity: relativeHumidity,
            paintSystemRaw: paintSystem.rawValue,
            closureRaw: closure.rawValue,
            usedModel: false
        ))
    }

    /// 结束（或取消）计时。
    func stop() {
        session = nil
        note = nil
        persist()
        cancelNotification()
    }

    /// 已经补过水了：从"现在"重新开始一轮。
    ///
    /// 不复用旧的 deadline —— 补完水之后干燥过程是从头开始的，
    /// 沿用旧时间会越算越离谱。
    func remisted() {
        startUsingModel()
        WKInterfaceDevice.current().play(.success)
    }

    private func begin(_ newSession: WatchWetnessSession) {
        session = newSession
        note = nil
        persist()
        scheduleNotification(for: newSession)
        WKInterfaceDevice.current().play(.start)
    }

    // MARK: - 落盘

    private func persist() {
        let encoder = JSONEncoder()
        if let session, let data = try? encoder.encode(session) {
            UserDefaults.standard.set(data, forKey: Self.sessionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.sessionKey)
        }
        let settings: [String: Double] = [
            "temperatureC": temperatureC,
            "relativeHumidity": relativeHumidity,
            "notifyWhenDue": notifyWhenDue ? 1 : 0
        ]
        UserDefaults.standard.set(settings, forKey: Self.settingsKey)
    }

    private func restore() {
        if let settings = UserDefaults.standard.dictionary(forKey: Self.settingsKey) {
            if let t = settings["temperatureC"] as? Double { temperatureC = t }
            if let h = settings["relativeHumidity"] as? Double { relativeHumidity = h }
            if let n = settings["notifyWhenDue"] as? Double { notifyWhenDue = n > 0 }
        }
        if let data = UserDefaults.standard.data(forKey: Self.sessionKey),
           let restored = try? JSONDecoder().decode(WatchWetnessSession.self, from: data) {
            session = restored
        }
    }

    /// 输入变了要存一下（温湿度是手调的，用户不想每次重调）。
    func saveInputs() {
        persist()
    }

    // MARK: - 提醒

    private func scheduleNotification(for session: WatchWetnessSession) {
        guard notifyWhenDue else { return }
        // ⚠️ 用 async/await 版本，不用 completionHandler 版本：
        //    后者会把 UNUserNotificationCenter 这个非 Sendable 对象
        //    捕获进 @Sendable 闭包，在严格并发下是警告（将来是错误）。
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else {
                // 不给通知权限也能用 —— 但要说清"到点不会响"，
                // 不能默默什么都不做，那样用户会以为是 App 坏了。
                self.note = "没有通知权限，到点不会提醒（只在表上看得到）。"
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "该补喷水了"
            content.body = "颜料调好后已经 \(self.predictedMinutes) 分钟，补一下水再继续。"
            content.sound = .default

            let interval = max(1, session.remistDeadline.timeIntervalSinceNow)
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: interval, repeats: false
            )
            let request = UNNotificationRequest(
                identifier: Self.notificationID, content: content, trigger: trigger
            )
            try? await center.add(request)
        }
    }

    private func cancelNotification() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }
}
