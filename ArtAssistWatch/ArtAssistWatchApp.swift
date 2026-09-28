//
//  ArtAssistWatchApp.swift
//  ArtAssist — 美术生的工具箱（Apple Watch 端）
//
//  ── 手表端做什么、不做什么，以及为什么 ───────────────────────
//  美术生画画时手是脏的、手机在桌上或包里，**抬手能看的那点东西才值得做**。
//  所以这里只放两件真正"在手腕上更顺手"的事：
//
//    1. 保湿计时 —— 调完色要记得补喷水。这件事的本质是"过一会儿提醒我"，
//       而提醒最该出现在手腕上（手腕会震，手机在包里不会）。
//       预测用的是和 iOS 端**同一个** `DryingModel`（同一份源码编译进来），
//       所以两边的结论一致。
//
//    2. 采购清单 —— 在美术用品店里一只手拿东西、一只手划清单，
//       比掏 iPad 现实得多。
//
//  ── 为什么不做"看颜料盒余量" ─────────────────────────────────
//  那需要把手机上的数据搬到表上，而本项目**刻意不使用任何 entitlement**
//  （免费 Apple ID 签不了 App Group / iCloud）。能跨设备同步的
//  WatchConnectivity 需要配对的 iPhone —— 而本 App 实际装在 iPad 上，
//  iPad 不支持 WCSession。所以搬数据这条路在当前的交付方式下走不通，
//  硬做一个"表上的颜料盒"只会是一份和手机对不上的假数据。
//  与其那样，不如只做**在表上能独立成立**的功能。
//
//  这两个功能的数据都只存在表上（各自一份 UserDefaults），完全离线可用。
//

import SwiftUI

@main
struct ArtAssistWatchApp: App {

    /// 保湿计时状态。放在 App 一级，切换 Tab 不丢。
    @State private var wetness = WatchWetnessStore()
    /// 采购清单。
    @State private var shopping = WatchShoppingStore()

    var body: some Scene {
        WindowGroup {
            WatchRootView(wetness: wetness, shopping: shopping)
        }
    }
}

/// 两个 Tab + 一个说明页。
struct WatchRootView: View {

    let wetness: WatchWetnessStore
    let shopping: WatchShoppingStore

    var body: some View {
        TabView {
            WatchWetnessView(store: wetness)
            WatchShoppingListView(store: shopping)
            WatchHelpView()
        }
        // watchOS 10 起用 containerBackground 声明背景，
        // 不写的话部分表盘/常亮模式下背景会发灰。
        .containerBackground(.black.gradient, for: .tabView)
    }
}

/// 说明页：把"能做什么、不能做什么"摆在表上，省得用户猜。
struct WatchHelpView: View {

    var body: some View {
        NavigationStack {
            List {
                Section("保湿计时") {
                    Text("调完色点开始，到点前会震一下提醒你补喷水。")
                        .font(.footnote)
                    Text("预测用的是和 iPad 上同一个干燥模型：温湿度越低越干得快。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("采购清单") {
                    Text("在店里买画材时对着划掉。清单只存在手表上。")
                        .font(.footnote)
                }
                Section("关于") {
                    Text("手表上是独立的两件小事，不会改动 iPad 上的库存数据。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("颜料盒余量、在途包裹这些要看 iPad。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("说明")
        }
    }
}
