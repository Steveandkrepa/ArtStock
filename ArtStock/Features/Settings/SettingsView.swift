//
//  SettingsView.swift
//  ArtAssist — 美术生的工具箱
//
//  设置。刻意保持极短 —— 个人工具不需要一堆开关。
//  这里只有：盒子概览、数据量、清空数据、关于。
//

import AVFoundation
import SwiftData
import SwiftUI
import UserNotifications

struct SettingsView: View {

    let bootstrap: ArtStockBootstrap
    let permissions: PermissionCoordinator

    @Environment(\.modelContext) private var context

    @Query private var boxes: [PaletteBox]
    @Query private var colors: [PaintColor]
    @Query private var supplies: [SupplyItem]
    @Query private var events: [RefillEvent]

    @State private var isShowingResetConfirm = false
    @State private var resetDone = false
    @State private var isShowingAPISettings = false
    @State private var dxartSession = DXArtSession.shared
    @State private var taobaoStore = TaobaoSessionStore.shared
    @State private var isShowingTaobaoOrders = false
    @State private var isShowingCityPicker = false
    @State private var sprayMinutes: Double = WetnessPreferences.minutesPerSpray
    @State private var notificationsOn: Bool = WetnessPreferences.notificationsEnabled
    @State private var outcome: String?

    private var box: PaletteBox? { boxes.first }

    var body: some View {
        Form {
            if bootstrap.isDegraded {
                Section {
                    NoticeBanner(
                        level: .error,
                        title: "数据没有加载出来，当前在临时内存库上",
                        message: bootstrap.degradedReason ?? ""
                    )
                    if let info = ArtStockStore.localStoreFileInfo() {
                        InfoRow(label: "数据文件",
                                value: info.exists ? "在（\(info.sizeText)）" : "不存在",
                                symbolName: info.exists ? "internaldrive.fill" : "questionmark.folder",
                                tint: info.exists ? .green : .red)
                        InfoRow(label: "位置", value: info.path)
                    }
                } footer: {
                    // ⚠️ 原来这里写的是"请到下方「清空并重建」" ——
                    //    那句是**错的**，而且很危险：清空重建会把磁盘上完好的
                    //    数据文件真的删掉。数据文件在模型修好之后是能自己回来的。
                    Text("""
                    磁盘上的数据文件**没有被删除**，修好之后会自己回来。
                    现在录的东西不会保存，也**不要**点「清空并重建」——那才会真的删掉。
                    把上面的原因发给我。
                    """)
                }
            }

            environmentSection
            wetnessSection
            boxSection
            dataSection
            maintenanceSection
            textbookAPISection
            taobaoSection
            aboutSection
        }
        .formStyle(.grouped)
        .artScrollEdgeEffect()
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .alert("确认清空所有数据？", isPresented: $isShowingResetConfirm) {
            Button("清空", role: .destructive) { resetStore() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除 \(colors.count) 个颜色、\(supplies.count) 项耗材和全部格子分配。此操作不可撤销。")
        }
        .task {
            await permissions.refresh()
        }
        // ⚠️ 四个 sheet 全部挂在 Form 上，**不要挂在 Section 上**。
        //    挂在 Section 上会"第一次点开自己关掉、第二次就正常"：
        //    Form 会复用/回收 Section 的宿主视图，sheet 的锚点跟着被换掉，
        //    于是刚弹出就被拆掉。第二次因为布局已经稳定才侥幸没事。
        .sheet(isPresented: $isShowingCityPicker) {
            CityPickerSheet()
        }
        .sheet(isPresented: $isShowingAPISettings) {
            DXArtAPISettingsView(session: dxartSession)
        }
        .sheet(isPresented: $isShowingTaobaoOrders) {
            TaobaoOrdersView(store: taobaoStore)
        }
        .alert("通知", isPresented: .presentWhen($outcome)) {
            Button("好") { outcome = nil }
        } message: {
            Text(outcome ?? "")
        }
        .alert("已清除数据文件", isPresented: $resetDone) {
            Button("好") {}
        } message: {
            Text("请完全退出 App（从多任务界面划掉）后重新打开，空的颜料盒会被自动建立。")
        }
    }

    // MARK: - 盒子

    private var boxSection: some View {
        Section {
            if let box {
                InfoRow(label: "名称", value: box.name, symbolName: "square.grid.3x3")
                InfoRow(label: "尺寸", value: "\(box.rows) × \(box.columns) = \(box.totalWells) 格",
                        symbolName: "ruler")
                InfoRow(label: "已装颜色", value: "\(box.assignedWellCount) 格", symbolName: "paintpalette")
                InfoRow(label: "需要补充", value: "\(box.wellsNeedingRefill.count) 格",
                        symbolName: "exclamationmark.triangle",
                        tint: box.wellsNeedingRefill.isEmpty ? .secondary : .orange)
            } else {
                Text("还没有建立颜料盒。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("颜料盒")
        } footer: {
            Text("改盒子尺寸请到「颜料盒」页面右上角的设置按钮。")
        }
    }

    // MARK: - 运行环境

    private var environmentSection: some View {
        Section {
            HStack {
                Label("运行方式", systemImage: "app.badge")
                Spacer()
                Text(RuntimeEnvironment.isLiveContainer ? "LiveContainer" : "直接安装")
                    .font(.caption)
                    .foregroundStyle(RuntimeEnvironment.isLiveContainer ? .orange : .secondary)
            }

            HStack {
                Label("相机权限", systemImage: "camera")
                Spacer()
                Text(cameraStatusText)
                    .font(.caption)
                    .foregroundStyle(cameraStatusColor)
            }

            HStack {
                Label("通知权限", systemImage: "bell.badge")
                Spacer()
                Text(notificationStatusText)
                    .font(.caption)
                    .foregroundStyle(notificationStatusColor)
            }

            // 还能重新申请：从没问过就直接弹窗；问过被拒了，弹窗不会再来，
            // 这时只能去系统设置 —— 所以按钮文案也分情况。
            if permissions.cameraStatus == .notDetermined || permissions.notificationStatus == .notDetermined {
                Button {
                    Task { await permissions.requestAll() }
                } label: {
                    Label("申请还没问过的权限", systemImage: "hand.raised")
                }
                .disabled(permissions.isRequesting)
            }

            if RuntimeEnvironment.isLiveContainer {
                NoticeBanner(
                    level: .warning,
                    title: "LiveContainer 环境注意事项",
                    message: "LiveContainer 的权限是**全局**的 —— 相机和通知的开关都在 LiveContainer 身上，"
                           + "不在这个 App 上。下面两条是你要去开的地方。"
                )
            }

            Button {
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
            } label: {
                Label("打开系统设置", systemImage: "gear")
            }
        } header: {
            Text("运行环境")
        } footer: {
            if RuntimeEnvironment.isLiveContainer {
                Text("""
                ① 相机：系统「设置」→ LiveContainer → 相机
                ② 通知：长按容器里的本 App → 打开 Fix Local Notifications
""")
            } else {
                Text("扫码与解析全部在本机完成；位置只用于查天气获取湿度。")
            }
        }
    }

    private var cameraStatusText: String {
        switch permissions.cameraStatus {
        case .authorized: return "已授权"
        case .notDetermined: return "尚未询问"
        case .denied: return "已拒绝"
        case .restricted: return "受系统限制"
        @unknown default: return "未知"
        }
    }

    private var cameraStatusColor: Color {
        permissions.cameraStatus == .authorized ? .green : .orange
    }

    private var notificationStatusText: String {
        switch permissions.notificationStatus {
        case .authorized: return "已授权"
        case .notDetermined: return "尚未询问"
        case .denied: return "已拒绝"
        case .provisional: return "临时授权"
        case .ephemeral: return "临时授权"
        @unknown default: return "未知"
        }
    }

    private var notificationStatusColor: Color {
        permissions.notificationStatus == .authorized ? .green : .orange
    }

    // MARK: - 保湿计时

    private var wetnessSection: some View {
        Section {
            Button {
                isShowingCityPicker = true
            } label: {
                HStack {
                    Label("城市", systemImage: "location")
                    Spacer()
                    Text(WetnessPreferences.city?.name ?? "使用当前位置")
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack {
                Label("喷一下能维持", systemImage: "spraybottle.fill")
                Spacer()
                TextField("0", value: $sprayMinutes, format: .number.precision(.fractionLength(0)))
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 64)
                    .onChange(of: sprayMinutes) { _, newValue in
                        WetnessPreferences.minutesPerSpray = newValue
                    }
                Text("分钟")
                    .foregroundStyle(.secondary)
            }

            Toggle(isOn: $notificationsOn) {
                Label("到点提醒", systemImage: "bell")
            }
            .onChange(of: notificationsOn) { _, newValue in
                WetnessPreferences.notificationsEnabled = newValue
                if newValue {
                    Task { _ = await NotificationService.ensureAuthorized() }
                }
            }

            Button {
                Task {
                    let ok = await NotificationService.sendTestNotification()
                    outcome = ok ? "测试提醒已排定，3 秒后应该会弹出来。" : "没能排定提醒，请检查系统的通知权限。"
                }
            } label: {
                Label("发一条测试提醒", systemImage: "bell.badge")
            }
        } header: {
            Text("保湿计时")
        } footer: {
            Text("城市用于获取当地湿度预测颜料干燥时间；不设则使用系统定位。\n"
                 + "「喷一下能维持多久」需要你自己量一次 —— 喷一下后掐表看能撑多少分钟。"
                 + "标定之后，到点提醒里就会给出「建议喷几下」。\n"
                 + "提醒是**本地通知**，不需要联网，也不需要任何特殊权限。")
        }
    }

    // MARK: - 数据

    private var dataSection: some View {
        Section("数据") {
            LabeledContent("颜色库", value: "\(colors.count) 个")
            LabeledContent("其他耗材", value: "\(supplies.count) 项")
            LabeledContent("补充记录", value: "\(events.count) 条")
            LabeledContent("存储占用", value: storeSizeText)
        }
    }

    private var storeSizeText: String {
        let fileManager = FileManager.default
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return "—"
        }
        let names = ["ArtStock.store", "ArtStock.store-shm", "ArtStock.store-wal",
                     "default.store", "default.store-shm", "default.store-wal"]
        var total: Int64 = 0
        for name in names {
            let url = support.appendingPathComponent(name)
            if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
               let size = attributes[.size] as? Int64 {
                total += size
            }
        }
        guard total > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    // MARK: - 维护

    private var maintenanceSection: some View {
        Section {
            Button(role: .destructive) {
                isShowingResetConfirm = true
            } label: {
                Label("清空并重建", systemImage: "trash")
            }
        } header: {
            Text("维护")
        } footer: {
            Text("会删除磁盘上的全部数据。因为运行中的数据库无法原地重建，删除后需要完全退出并重新打开 App。")
        }
    }

    private func resetStore() {
        _ = ArtStockStore.destroyLocalStore()
        Haptics.alert()
        resetDone = true
    }

    // MARK: - 教材接口

    /// 教材平台的接口设置。
    ///
    /// 这一段存在的理由见 `DXArtAPISettingsView` 的说明：
    /// 域名和版本号是从厂家客户端逆向出来的，厂家一升级就可能失效。
    /// 露出来，用户至少能自己试出正确的版本号，而不用等重新打包。
    private var textbookAPISection: some View {
        Section {
            LabeledContent("登录状态", value: dxartSession.isLoggedIn ? "已登录" : "未登录")
            LabeledContent("接口域名", value: dxartSession.config.host)
                .font(.caption)

            Button {
                isShowingAPISettings = true
            } label: {
                Label("接口设置", systemImage: "network")
            }

            if dxartSession.isLoggedIn {
                Button(role: .destructive) {
                    dxartSession.logout()
                    Haptics.alert()
                } label: {
                    Label("退出教材平台登录", systemImage: "person.badge.minus")
                }
            }
        } header: {
            Text("教材")
        } footer: {
            Text("教材搜索与下载用的是平台账号。凭证只存在本机 Keychain 里，"
                 + "不进备份、不上传。接口地址与版本号可以在这里改 —— "
                 + "厂家升级后如果突然用不了，先来这儿把版本号改成最新版试试。")
        }
    }

    // MARK: - 淘宝

    /// 淘宝账号与订单。
    ///
    /// 读订单只有一条路：**打开淘宝自己的网页 → 截图认字**。
    /// 所以这里没有"接口设置"这种东西了 —— 没有接口可设。
    private var taobaoSection: some View {
        Section {
            LabeledContent("账号", value: taobaoStore.activeAccount?.displayName ?? "未登录")
            LabeledContent("登录状态",
                           value: taobaoStore.isLoggedIn ? "已确认登录" : "未确认")

            Button {
                isShowingTaobaoOrders = true
            } label: {
                Label("淘宝账号与订单", systemImage: "cart")
            }

            if taobaoStore.activeAccount != nil {
                Button(role: .destructive) {
                    // logout 是 async：它还要清这份档案里的网页会话
                    Task {
                        await taobaoStore.logout()
                        Haptics.alert()
                    }
                } label: {
                    Label("退出淘宝登录", systemImage: "person.badge.minus")
                }
            }
        } header: {
            Text("淘宝（可选）")
        } footer: {
            Text("""
            用来把淘宝订单里的商品清单同步进「在途」，到货时一键入库。
            登录在 App 内的网页里完成，密码只输在淘宝自己的页面上；
            每个账号各有一份**独立的浏览器档案**（cookie、缓存都分开），
            所以切换账号不用重新输密码，也能随时退出。

            读取订单时**只截图认字**：不改动页面、不拦截请求、不猜接口、
            不做轮询和后台刷新。如果不放心，可以完全不用它：
            在「在途」里粘贴订单文字同样能建包裹，而且完全离线。
            """)
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section {
            LabeledContent("应用", value: "ArtAssist")
            LabeledContent("版本", value: appVersion)
            LabeledContent("最低系统", value: "iOS / iPadOS 17.0")
            LabeledContent("数据存储", value: "仅本机")
            HStack {
                Label("外观", systemImage: "sparkles")
                Spacer()
                Text(LiquidGlassSupport.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("关于")
        } footer: {
            Text("识别、取色、库存计算与阅读都在本机完成。"
                 + "联网只有两处：查当地天气、搜/下教材。"
                 + "不用 iCloud、推送与第三方统计。")
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - 城市选择

/// 不想开定位时，手动指定一个城市。
///
/// 城市用 Open-Meteo 的免费地理编码接口搜，中文城市名可以直接搜。
struct CityPickerSheet: View {

    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [WeatherService.Place] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

    private let service = WeatherService()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Label("当前设定", systemImage: "location.fill")
                        Spacer()
                        Text(WetnessPreferences.city?.name ?? "使用系统定位")
                            .foregroundStyle(.secondary)
                    }
                    if WetnessPreferences.city != nil {
                        Button("改用系统定位") {
                            WetnessPreferences.city = nil
                            dismiss()
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                if !results.isEmpty {
                    Section("搜索结果") {
                        ForEach(results) { place in
                            Button {
                                WetnessPreferences.city = (place.name, place.latitude, place.longitude)
                                Haptics.saved()
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(place.name)
                                        .foregroundStyle(.primary)
                                    Text(place.displayName)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "输入城市名，如「杭州」")
            .onSubmit(of: .search) { Task { await search() } }
            .onChange(of: query) { _, newValue in
                guard newValue.count >= 2 else { results = []; return }
                Task { await search() }
            }
            .navigationTitle("指定城市")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .overlay {
                if isSearching {
                    ProgressView()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func search() async {
        isSearching = true
        errorMessage = nil
        defer { isSearching = false }
        do {
            results = try await service.searchPlaces(matching: query)
            if results.isEmpty { errorMessage = "没找到这个城市，换个写法试试。" }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
