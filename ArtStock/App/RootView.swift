//
//  RootView.swift
//  ArtAssist — 美术生的工具箱
//
//  iPad 两栏布局：
//    侧边栏 —— 几个分区（颜料盒 / 保湿计时 / 教材 / 颜色库 / 库存与采购 / 设置）
//
//  降级到内存库时会在启动弹一次告警：静默降级会把"模型不兼容"伪装成
//  "数据丢了"，用户第一反应是重新录入，那才是真的白干。
//    主区域 —— 当前分区的全部内容
//
//  为什么是两栏而不是三栏：三栏（列表-详情-检视器）是仓库软件的骨架，
//  适合"在几千条记录里检索"。这里只有一盒 42 格颜料，主界面就该是
//  **一整盒的网格**，点开某一格再用弹层处理 —— 两栏足够，且主区域能留得更大。
//

import SwiftData
import SwiftUI

struct RootView: View {

    let bootstrap: ArtStockBootstrap

    @State private var permissions = PermissionCoordinator()
    @State private var section: AppSection? = .palette
    @State private var isShowingScanner = false
    @State private var isShowingOnboarding = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// 降级告警是否已展示过（只在启动时弹一次，不反复烦人）。
    @State private var isShowingDegradedAlert = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(section: $section, onScan: { isShowingScanner = true })
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .fullScreenCover(isPresented: $isShowingScanner) {
            PaintScanView()
        }
        .fullScreenCover(isPresented: $isShowingOnboarding) {
            PermissionOnboardingView(coordinator: permissions) {
                isShowingOnboarding = false
            }
        }
        .task {
            // 启动时刷新权限状态，并在首次运行时主动引导申请。
            // 权限弹窗本来就该在首次打开时出现，跟其他 App 一样 ——
            // 藏到用户点进扫码页之后再问，很容易因为视图层级问题根本问不出来。
            await permissions.refresh()
            if permissions.needsOnboarding {
                isShowingOnboarding = true
            }
            // 数据没落盘，必须**立刻**说，不能等用户去设置页才发现。
            if bootstrap.isDegraded {
                isShowingDegradedAlert = true
            }
        }
        .alert("数据没有加载出来", isPresented: $isShowingDegradedAlert) {
            Button("我知道了") {}
        } message: {
            Text(degradedMessage)
        }
    }

    /// 降级告警的正文。
    ///
    /// 措辞刻意把三件事说清楚，因为它们直接决定用户该做什么：
    ///   1. **文件还在** —— 否则用户会立刻开始重新录入，白费功夫
    ///   2. **现在别录** —— 内存库里的东西进程一退就没了
    ///   3. **别点清空重建** —— 那才是真的把数据删掉
    private var degradedMessage: String {
        var lines = [
            "App 现在跑在临时内存库上，往里录的东西退出后不会保存。",
            "",
            "你的数据文件**还在磁盘上，没有被删除**："
        ]
        if let info = ArtStockStore.localStoreFileInfo() {
            lines.append("· \(info.exists ? "存在" : "不存在")，\(info.sizeText)")
        }
        lines.append("")
        lines.append("原因：\(bootstrap.degradedReason ?? "未知")")
        lines.append("")
        lines.append("先别录新数据，也**不要**点「清空并重建数据库」——那才会真的删掉。")
        lines.append("把这条消息发给我，我看具体原因。")
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private var detail: some View {
        switch section ?? .palette {
        case .palette:
            PaletteGridView(isDegraded: bootstrap.isDegraded)
        case .wetness:
            WetnessView()
        case .textbooks:
            TextbookLibraryView()
        case .colors:
            ColorLibraryView()
        case .stock:
            StockView()
        case .settings:
            SettingsView(bootstrap: bootstrap, permissions: permissions)
        }
    }
}

// MARK: - 侧边栏

private struct SidebarView: View {

    @Binding var section: AppSection?
    var onScan: () -> Void

    @Environment(\.modelContext) private var modelContext

    @Query private var boxes: [PaletteBox]
    @Query private var colors: [PaintColor]
    @Query private var supplies: [SupplyItem]
    @Query private var books: [Textbook]

    var body: some View {
        List(selection: $section) {
            Section {
                ForEach(AppSection.allCases) { item in
                    Label {
                        HStack {
                            Text(item.title)
                            Spacer(minLength: 0)
                            if let count = badge(for: item), count > 0 {
                                Text("\(count)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.orange, in: Capsule())
                            }
                        }
                    } icon: {
                        Image(systemName: item.symbolName)
                    }
                    .tag(item)
                }
            }

            Section {
                Button(action: onScan) {
                    Label("扫颜料包装入库", systemImage: "barcode.viewfinder")
                }
            }
        }
        .listStyle(.sidebar)
        // 侧边栏标题 = App 名。iPad 上这个标题同时是窗口标题与
        // App 切换器里显示的名字，之前一直是颜料盒的名字（"我的颜料盒"）。
        // 颜料盒自己的名字在「颜料盒」那一页的标题上。
        .navigationTitle("ArtAssist")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 侧边栏角标：只显示"需要你动手"的数量。
    private func badge(for section: AppSection) -> Int? {
        switch section {
        case .palette:
            return boxes.first?.wellsNeedingRefill.count ?? 0
        case .stock:
            // 角标要算**两边**：颜料缺几个颜色 + 耗材几项该补。
            // 只算颜料的话，耗材缺货时角标不亮，用户就不会点进来 ——
            // 那这次"并进库存体系"就白做了。
            let paint = PaletteService.purchasePlan(for: colors).suggestions.count
            return paint + supplies.filter(\.needsRestock).count
        case .wetness:
            // 侧边栏角标：正在计时就显示 1，提示"有东西在跑"。
            let active = (try? modelContext.fetch(FetchDescriptor<WetnessSession>()))?
                .contains { $0.status.isActive } ?? false
            return active ? 1 : 0
        case .textbooks:
            // 角标 = 还没下完的教材数（只在有教材时才亮）
            return books.filter { !$0.isFullyDownloaded && $0.pageCount > 0 }.count
        case .colors, .settings:
            return nil
        }
    }
}

#if DEBUG
#Preview {
    RootView(bootstrap: ArtStockBootstrap(container: PreviewData.container, degradedReason: nil))
        .modelContainer(PreviewData.container)
}
#endif
