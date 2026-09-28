//
//  ArtStockApp.swift
//  ArtAssist — 美术生的工具箱
//
//  iPad 优先的原生美术生工具箱 App：颜料盒余量、保湿计时、教材阅读。
//  支持本地二维码扫描识别建库，全部数据留在设备本机。
//

import SwiftData
import SwiftUI
import UserNotifications

@main
struct ArtStockApp: App {

    /// 容器只创建一次。
    ///
    /// 创建失败时 `ArtStockStore` 会降级到内存库并把原因带出来，
    /// 由设置页提示用户重置数据库——而不是让 App 在启动时崩掉。
    private let bootstrap: ArtStockBootstrap

    init() {
        bootstrap = ArtStockStore.bootstrap()

        // 让通知在 App 处于前台时也能弹出横幅。
        // 默认情况下 iOS 在前台会静默丢弃通知 —— 而用户很可能正开着
        // 这个 App 等提醒，那样就完全看不到了。
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView(bootstrap: bootstrap)
        }
        .modelContainer(bootstrap.container)
    }
}
