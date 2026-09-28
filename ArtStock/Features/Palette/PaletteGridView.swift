//
//  PaletteGridView.swift
//  ArtAssist — 美术生的工具箱
//
//  **主界面**：一整盒 7×6 网格。
//
//  设计目标只有一个：一屏看完整盒，一眼看出哪几格该补。
//  所以：
//    · 格子的主角是颜色本身，文字只留一个位置编号
//    · 余量用底部细条表示，不满才画 —— 42 格全画会变成噪声
//    · 该补的格子右上角一个标记，别的地方一律不加装饰
//

import SwiftData
import SwiftUI

struct PaletteGridView: View {

    @Environment(\.modelContext) private var context

    @Query(sort: \PaletteBox.createdAt) private var boxes: [PaletteBox]
    @Query private var colors: [PaintColor]

    @State private var editingWell: PaletteWell?
    @State private var isShowingBoxSetup = false
    @State private var isCalibrating = false
    @State private var isShowingPresetReplace = false
    @State private var presetOutcome: String?
    /// 正在被拖动的那一格（位置标签）。
    @State private var draggingLabel: String?
    /// 当前悬停的落点（位置标签），用来高亮。
    @State private var dropTargetLabel: String?
    /// 正在补货中的颜色色号。有在途补充装的格子画个小标记。
    @State private var incomingColorCodes: Set<String> = []
    /// 首次运行是否已经自动装好 42 色预设 —— 只做一次，之后不再插手用户的分配。
    @AppStorage("hasAutoLoadedPresetColors") private var hasAutoLoadedPreset = false
    /// 本地已应用的色卡数据版本。低于 `PresetColors.dataVersion` 就自动刷一次。
    @AppStorage("presetColorDataVersion") private var appliedPresetDataVersion = 0
    /// 当前是不是跑在内存库上（数据没落盘）。
    var isDegraded: Bool = false

    private var box: PaletteBox? { boxes.first }

    var body: some View {
        Group {
            if let box {
                content(for: box)
            } else {
                ProgressView()
                    .task { _ = PaletteService.loadOrCreateBox(in: context) }
            }
        }
        .navigationTitle(box?.name ?? "颜料盒")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(item: $editingWell) { well in
            WellEditorSheet(well: well)
        }
        .sheet(isPresented: $isShowingBoxSetup) {
            if let box { BoxSetupSheet(box: box) }
        }
        .fullScreenCover(isPresented: $isCalibrating) {
            ColorCalibrationView()
        }
        .confirmationDialog("载入预设色卡", isPresented: $isShowingPresetReplace, titleVisibility: .visible) {
            if let box {
                Button("替换盒子里所有格子", role: .destructive) {
                    let result = PaletteService.loadPresetColors(into: box, overwrite: true, in: context)
                    presetOutcome = "已载入 42 色：新建 \(result.colorsCreated) 个颜色，填入 \(result.wellsFilled) 格。"
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会覆盖盒子里已有的颜色分配。如果只是想补上空的格子，用「只填空格」。")
        }
        .alert("预设色卡", isPresented: .presentWhen($presetOutcome)) {
            Button("好") { presetOutcome = nil }
        } message: {
            Text(presetOutcome ?? "")
        }
    }

    // MARK: - 主体

    private func content(for box: PaletteBox) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                summaryCard(for: box)
                grid(for: box)
                legend
            }
            .padding(20)
            .frame(maxWidth: Theme.maxGridWidth)
            .frame(maxWidth: .infinity)
        }
        .artScrollEdgeEffect()
        .task {
            autoLoadPresetIfFirstRun(box)
            refreshPresetDataIfNeeded()
            refreshIncomingMarkers()
        }
    }

    /// 刷新"哪些颜色正在补货中"。
    ///
    /// 从在途包裹清单里取：还没入库的颜色补充装都算"正在补货"。
    /// 采一次放集合里，42 格各自 O(1) 查，不用每格都去查库。
    private func refreshIncomingMarkers() {
        incomingColorCodes = Set(
            IncomingPackageService.incomingSupplies(in: context)
                .filter { $0.isColor }
                .map { $0.code }
        )
    }

    // MARK: - 首次运行自动装预设

    /// 第一次打开时直接把 42 色预设装好。
    ///
    /// 为什么自动做：这盒颜料本来就有 42 格，而 42 色水粉是标准配置。
    /// 把"载入预设"藏进右上角菜单里，用户看到的是一盒**空格子**，
    /// 第一反应是"这 App 什么都没有" —— 一个空格子网格什么也说明不了。
    ///
    /// 只在两种情况下自动装：颜色库为空 **且** 一个颜色都没分配。
    /// 只要你动过任何一个格子，这条路就永久关闭（AppStorage 标记），
    /// 绝不会在你不注意的时候把颜色冲掉。
    private func autoLoadPresetIfFirstRun(_ box: PaletteBox) {
        // 降级到内存库时**绝对不要**自动装预设：
        // 那是往一个进程结束就消失的库里写 42 条数据，
        // 用户会以为"数据被重置了"，其实什么都没保存。
        guard !isDegraded else { return }
        guard !hasAutoLoadedPreset else { return }
        guard colors.isEmpty, box.assignedWellCount == 0 else {
            hasAutoLoadedPreset = true
            return
        }
        let result = PaletteService.loadPresetColors(into: box, overwrite: false, in: context)
        hasAutoLoadedPreset = true
        if result.wellsFilled > 0 {
            presetOutcome = """
            已按 42 色的常见排布装满（新建 \(result.colorsCreated) 个颜色，填入 \(result.wellsFilled) 格）。

            色值取自厂家色卡。觉得不像，进「颜色库」改。
"""
        }
    }

    // MARK: - 色卡数据升级

    /// 老版本装过预设、色值是**按色名猜**的（「马尔代夫」当时是蓝的）。
    /// 色卡数据换了之后自动刷一次，用户不用自己去找菜单 ——
    /// 真实反馈就是"颜色不对"，让他自己找到那个菜单项才修是不合理的。
    ///
    /// 三条安全边界（都在 `refreshPresetColors` 里）：
    ///   · 取色校准过的颜色不覆盖
    ///   · 改过名的颜色不覆盖
    ///   · 用户自己建的颜色不碰（只处理 PRESET-xx）
    private func refreshPresetDataIfNeeded() {
        // ⚠️ 这条 guard 是修一个真实事故加的。
        //
        // 降级到内存库时，刷新"什么也没做"（库是空的），
        // 但下面那行会把 `appliedPresetDataVersion` 写成最新版 ——
        // 而这个标记存在 UserDefaults 里，**跟 store 无关**。
        // 于是等真 store 又能打开时，这里会因为"已经是版本 2"直接跳过，
        // 老的猜测色值（马尔代夫是蓝的）就永远留在那儿了。
        // 用户看到的正是「预设又乱掉了」。
        guard !isDegraded else { return }
        guard appliedPresetDataVersion < PresetColors.dataVersion else { return }
        let updated = PaletteService.refreshPresetColors(in: context)
        appliedPresetDataVersion = PresetColors.dataVersion
        guard updated > 0 else { return }
        presetOutcome = """
        色卡已更新：\(updated) 个颜色换成了厂家色卡上的实测色值。

        校准过或改过名的颜色没有被覆盖。
        """
    }

    // MARK: - 汇总条

    private func summaryCard(for box: PaletteBox) -> some View {
        let needing = box.wellsNeedingRefill
        let plan = PaletteService.purchasePlan(for: colors)
        let noStock = needing.filter { well in
            guard let color = well.color else { return false }
            return color.refills.allSatisfy { $0.refillCapacity <= 0 }
        }

        return VStack(alignment: .leading, spacing: 10) {
            if needing.isEmpty {
                Label("整盒都够用", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(.green)
                Text("\(box.assignedWellCount) / \(box.totalWells) 格装了颜色，暂时没有需要补的。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("\(needing.count) 格该补了", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)

                HStack(spacing: 14) {
                    if !noStock.isEmpty {
                        Text("其中 \(noStock.count) 格没有补充装")
                            .foregroundStyle(.red)
                    }
                    if !plan.suggestions.isEmpty {
                        Text("建议买 \(plan.suggestions.count) 个颜色")
                            .foregroundStyle(.orange)
                    } else {
                        Text("抽屉里的库存够用，不用买")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - 网格

    private func grid(for box: PaletteBox) -> some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: Theme.gridSpacing),
                count: max(1, box.columns)
            ),
            spacing: Theme.gridSpacing
        ) {
            ForEach(box.orderedWells) { well in
                PaletteCellView(well: well, isSelected: editingWell?.id == well.id)
                    // 落点高亮：拖动时能看清会换到哪一格
                    .overlay {
                        if dropTargetLabel == well.positionLabel {
                            RoundedRectangle(cornerRadius: Theme.cellCornerRadius, style: .continuous)
                                .strokeBorder(Theme.accent, lineWidth: 3)
                        }
                    }
                    // 在途标记：这格的颜料正在补货中，一眼看出不用现在买。
                    .overlay(alignment: .topTrailing) {
                        if let code = well.color?.code, incomingColorCodes.contains(code) {
                            Image(systemName: "shippingbox.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(.green, in: Circle())
                                .padding(3)
                                .accessibilityLabel("在途")
                        }
                    }
                    // 被拖起来的那格淡出，避免"它还在原地"的错觉
                    .opacity(draggingLabel == well.positionLabel ? 0.35 : 1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingWell = well
                        Haptics.selection()
                    }
                    // 长按拖动换位。payload 直接用位置标签 ——
                    // 它在盒子里唯一，而且 String 本身就是 Transferable，
                    // 不用额外定义一个类型。
                    .draggable(well.positionLabel) {
                        PaletteCellView(well: well)
                            .frame(width: 64, height: 64)
                            .onAppear { draggingLabel = well.positionLabel }
                            .onDisappear { draggingLabel = nil }
                    }
                    .dropDestination(for: String.self) { items, _ in
                        guard let from = items.first else { return false }
                        return swap(from: from, to: well, in: box)
                    } isTargeted: { targeted in
                        dropTargetLabel = targeted ? well.positionLabel : nil
                    }
            }
        }
        .padding(Theme.gridSpacing)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 拖动换位

    /// 把 `from` 那一格的颜料换到 `target` 这一格。
    /// - Returns: 是否真的换了（拖回原位返回 false，系统就不做多余动画）。
    private func swap(from label: String, to target: PaletteWell, in box: PaletteBox) -> Bool {
        defer {
            draggingLabel = nil
            dropTargetLabel = nil
        }
        guard let source = box.wells.first(where: { $0.positionLabel == label }),
              source.persistentModelID != target.persistentModelID else { return false }

        PaletteService.swapWells(source, target, in: context)
        Haptics.saved()
        return true
    }

    // MARK: - 图例

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 把两个手势告诉用户 —— 不写出来没人会去长按格子试。
            HStack(spacing: 6) {
                Image(systemName: "hand.draw")
                    .font(.caption2)
                Text("点一下改余量 · 长按拖动可以换位置")
                    .font(.caption2)
            }
            .foregroundStyle(.tertiary)

            HStack(spacing: 14) {
                ForEach([WellLevel.full, .high, .half, .low, .empty], id: \.self) { level in
                    HStack(spacing: 4) {
                        Capsule()
                            .fill(Theme.color(for: level))
                            .frame(width: 14, height: 4)
                        Text(level.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    isCalibrating = true
                } label: {
                    Label("取色校准（按实物校正颜色）", systemImage: "camera.viewfinder")
                }

                Button {
                    isShowingBoxSetup = true
                } label: {
                    Label("盒子设置", systemImage: "slider.horizontal.3")
                }

                Divider()

                Button {
                    guard let box else { return }
                    let result = PaletteService.loadPresetColors(into: box, overwrite: false, in: context)
                    presetOutcome = result.wellsFilled == 0
                        ? "盒子里已经没有空格了。想整体重排请用「替换盒子里的全部格子」。"
                        : "已填入 42 色中的 \(result.wellsFilled) 格，新建 \(result.colorsCreated) 个颜色。"
                } label: {
                    Label("载入 42 色预设（只填空格）", systemImage: "paintpalette")
                }

                Button {
                    isShowingPresetReplace = true
                } label: {
                    Label("载入并替换全部格子", systemImage: "arrow.triangle.2.circlepath")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(box == nil)
        }
    }
}

// MARK: - 盒子设置
// MARK: - 盒子设置

struct BoxSetupSheet: View {

    let box: PaletteBox

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var rows: Int
    @State private var columns: Int

    init(box: PaletteBox) {
        self.box = box
        _name = State(initialValue: box.name)
        _rows = State(initialValue: box.rows)
        _columns = State(initialValue: box.columns)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("我的颜料盒", text: $name)
                }

                Section {
                    Stepper("行数：\(rows)", value: $rows, in: 1...12)
                    Stepper("列数：\(columns)", value: $columns, in: 1...12)
                } header: {
                    Text("尺寸")
                } footer: {
                    Text("当前共 \(rows * columns) 格。改小会删掉超出范围的格子（连同里面的颜色分配），"
                         + "改大会补上新的空格子。")
                }

                Section {
                    HStack {
                        Text("已装颜色")
                        Spacer()
                        Text("\(box.assignedWellCount) / \(box.totalWells) 格")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("当前状态")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("盒子设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        box.name = name.isBlank ? "我的颜料盒" : name.trimmed
                        PaletteService.resize(box, rows: rows, columns: columns, in: context)
                        Haptics.saved()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
