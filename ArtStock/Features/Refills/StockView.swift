//
//  StockView.swift
//  ArtAssist — 美术生的工具箱
//
//  「库存与采购」：**这个 App 兑现承诺的地方 —— 不缺也不过多。**
//
//  ── 页面顺序就是使用顺序 ─────────────────────────────────────
//      1. 统一结论：颜料 + 其他耗材，一句话说清总共要买什么
//      2. 需要动手的明细
//      3. 两个页签分别管理：颜料补充装 / 其他耗材
//  用户打开这一页，看完第一块就可以关掉。
//
//  ── 为什么耗材也在这里 ───────────────────────────────────────
//  真实反馈：「其他耗材也应该直接纳入库存与采购体系中啊」。
//  原来「其他耗材」是侧边栏一个独立分区，两边的结论各说各的 ——
//  一个说"建议买 3 个颜色"，另一个说"2 项快用完了"，
//  没有一处告诉你**总共要买什么**。那正是这里最该回答的问题。
//
//  ⚠️ 默认页签必须是「全部」而不是「要处理的」。
//     之前默认只显示要处理的，而刚载入 42 色预设时所有颜色都是"还没装进盒子"，
//     列表全空 → 用户以为"补充装库存"这个功能根本不存在（真实反馈）。
//

import SwiftData
import SwiftUI

struct StockView: View {

    @Environment(\.modelContext) private var context

    @Query(sort: \PaintColor.name) private var colors: [PaintColor]
    @Query private var supplies: [SupplyItem]

    @State private var editingColor: PaintColor?
    @State private var isPickingColor = false
    @State private var tab: Tab = .paint
    @State private var filter: Filter = .all
    /// 淘宝登录态。跨页签共享同一份（在设置里登录过这里就是登录状态）。
    @State private var taobaoStore = TaobaoSessionStore.shared

    enum Tab: String, CaseIterable, Identifiable {
        case paint
        case supplies
        case incoming

        var id: String { rawValue }
        var title: String {
            switch self {
            case .paint: return "颜料"
            case .supplies: return "耗材"
            case .incoming: return "在途"
            }
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all
        case actionable
        case unregistered
        case overstocked

        var id: String { rawValue }
        var title: String {
            switch self {
            case .actionable: return "要处理的"
            case .all: return "全部"
            case .unregistered: return "没登记的"
            case .overstocked: return "偏多的"
            }
        }
    }

    private var statuses: [ColorStockStatus] {
        PaletteService.statuses(for: colors)
    }

    private var plan: PurchasePlan {
        // 采购结论必须**扣掉在途**：已经在路上的补充装不该再买一次。
        PaletteService.purchasePlan(
            for: colors,
            incoming: IncomingPackageService.incomingSupplies(in: context)
        )
    }

    /// 耗材的取值快照 —— 统一结论要它。
    private var supplySnapshots: [SupplySnapshot] {
        supplies.map(\.snapshot)
    }

    private var supplyRestockLines: [SupplyRestockLine] {
        StockPlan.restockLines(from: supplySnapshots)
    }

    /// 在途包裹数（还没入库的）。采购结论里要提一句，
    /// 否则用户会看着"该买"的结论，忘掉已经在路上的那一单。
    private var incomingCount: Int {
        ((try? context.fetch(FetchDescriptor<IncomingPackage>())) ?? [])
            .filter { $0.status != .stocked }.count
    }

    private var visible: [ColorStockStatus] {
        switch filter {
        case .all: return statuses
        case .actionable: return statuses.filter { $0.isActionable }
        case .unregistered: return statuses.filter { $0.color.refills.isEmpty }
        case .overstocked: return statuses.filter { $0.state == .overstocked }
        }
    }

    private var unregisteredCount: Int {
        colors.filter { $0.refills.isEmpty }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                unifiedCard

                if colors.isEmpty && supplies.isEmpty {
                    EmptyState(
                        title: "还没有可管理的东西",
                        message: "打开「颜料盒」会自动按 42 色水粉装好一整盒；"
                               + "纸、笔、橡皮这些可以在下面的「其他耗材」里加。",
                        symbolName: "shippingbox"
                    )
                    .frame(minHeight: 220)
                }

                Picker("管理", selection: $tab) {
                    ForEach(Tab.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                switch tab {
                case .paint:
                    paintSection
                case .supplies:
                    SupplySectionView()
                case .incoming:
                    // 待收包裹：买了什么 → 到货 → 一键入库。
                    // 放在「库存与采购」里，因为采购的最后一公里就是入库。
                    IncomingPackageView(taobaoStore: taobaoStore)
                }
            }
            .padding(20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .artScrollEdgeEffect()
        .navigationTitle("库存与采购")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingColor) { color in
            RefillStockEditorSheet(color: color)
        }
        .sheet(isPresented: $isPickingColor) {
            // 复用颜色选择器：补充装库存是挂在颜色上的，所以先选颜色。
            ColorPickerSheet(current: nil) { picked in
                // 选择器自己会 dismiss，这里稍等一下再开编辑页 ——
                // 两个 sheet 同时切换会互相打断。
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(380))
                    editingColor = picked
                }
            }
        }
        .toolbar {
            if tab == .paint {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPickingColor = true
                    } label: {
                        Label("登记补充装", systemImage: "plus")
                    }
                    .disabled(colors.isEmpty)
                }
            }
        }
    }

    // MARK: - 颜料补充装

    @ViewBuilder
    private var paintSection: some View {
        if colors.isEmpty {
            EmptyState(
                title: "颜色库还是空的",
                message: "补充装库存是挂在颜色上的，所以要先有颜色 —— "
                       + "打开「颜料盒」就会自动按 42 色水粉的排布装好一整盒。",
                symbolName: "paintpalette"
            )
            .frame(minHeight: 200)
        } else {
            coverageCard
            filterBar

            if visible.isEmpty {
                noticeForEmptyFilter
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, status in
                        Button {
                            editingColor = status.color
                        } label: {
                            ColorStockRow(status: status)
                        }
                        .buttonStyle(.plain)

                        if index < visible.count - 1 {
                            Divider().padding(.leading, 54)
                        }
                    }
                }
                .cardStyle(padding: 8)
            }
        }
    }

    // MARK: - 统一结论（这次改动的重点）

    /// 颜料 + 耗材，一句话说清总共要买什么。
    private var unifiedCard: some View {
        let supplyLines = supplyRestockLines
        let isEmpty = StockPlan.isEmpty(paintColors: plan.suggestions.count, supplies: supplySnapshots)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isEmpty ? "checkmark.circle.fill" : "cart.fill")
                    .font(.title2)
                    .foregroundStyle(isEmpty ? .green : .orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text(isEmpty ? "暂时不用买" : "该补货了")
                        .font(.title3.weight(.semibold))
                    Text(StockPlan.summary(
                        paintColors: plan.suggestions.count,
                        paintUnits: plan.totalUnits,
                        supplies: supplySnapshots
                    ))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            if !plan.suggestions.isEmpty || !supplyLines.isEmpty {
                Divider()

                VStack(spacing: 8) {
                    // 颜料
                    ForEach(plan.suggestions) { suggestion in
                        HStack(spacing: 10) {
                            ColorDot(hex: suggestion.color.hex, size: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(suggestion.color.name)
                                    .font(.subheadline.weight(.medium))
                                Text(suggestion.reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let arrival = suggestion.incomingArrivalText,
                                   suggestion.incomingUnits > 0 {
                                    Label("在途 \(suggestion.incomingUnits) 件 · \(arrival)",
                                          systemImage: "shippingbox")
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                            Spacer(minLength: 8)
                            if suggestion.coveredByIncoming {
                                Label("不用买", systemImage: "checkmark")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.green)
                            } else {
                                Text("买 \(suggestion.units) \(suggestion.kind.unitName)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    // 耗材
                    ForEach(supplyLines) { line in
                        HStack(spacing: 10) {
                            Image(systemName: "shippingbox")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(line.name)
                                    .font(.subheadline.weight(.medium))
                                Text(line.reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text(line.categoryName)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                HStack(spacing: 16) {
                    Button {
                        tab = .supplies
                    } label: {
                        Label("去管理耗材", systemImage: "arrow.right")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)

                    if incomingCount > 0 {
                        Button {
                            tab = .incoming
                        } label: {
                            Label("有 \(incomingCount) 个包裹在途", systemImage: "shippingbox")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - 登记覆盖率

    /// "42 个颜色里还有几个没登记补充装"。
    ///
    /// 这一块是为了一句真实反馈加的：「库存管理割裂，而且预设也没有」——
    /// 打开这一页看到 42 行"还没有登记"确实很像功能没做完。
    /// 与其让用户猜要登记多少个，不如直接告诉他进度，并且一键筛出来。
    @ViewBuilder
    private var coverageCard: some View {
        if unregisteredCount > 0 {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "shippingbox")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(colors.count - unregisteredCount) / \(colors.count) 个颜色登记了补充装")
                        .font(.subheadline.weight(.medium))
                    Text("剩下 \(unregisteredCount) 个还不知道你手上有几支 —— 登记了才算出准数。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button("去登记") { filter = .unregistered }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        } else {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("\(colors.count) 个颜色的补充装都已登记，下面算出来的数字是准的。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle()
        }
    }

    // MARK: - 筛选

    private var filterBar: some View {
        Picker("筛选", selection: $filter) {
            ForEach(Filter.allCases) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var noticeForEmptyFilter: some View {
        switch filter {
        case .actionable:
            NoticeBanner(level: .success,
                         title: "没有要处理的颜色",
                         message: "盒子里没有缺的，库存也没有缺口。")
        case .unregistered:
            NoticeBanner(level: .success,
                         title: "每个颜色都登记过了",
                         message: "42 个颜色的补充装库存都已经有记录。")
        case .overstocked:
            NoticeBanner(level: .success,
                         title: "没有偏多的颜色",
                         message: "库存量都还合理。")
        case .all:
            EmptyView()
        }
    }
}

// MARK: - 颜色行

private struct ColorStockRow: View {

    let status: ColorStockStatus

    /// 某一种补充装还有多少。返回 nil 表示没登记或已用尽。
    private func stockText(for kind: RefillKind) -> String? {
        guard let stock = status.color.refills.first(where: { $0.kind == kind }) else { return nil }
        guard stock.units > 0 || stock.partialCapacity > 0 else { return nil }

        switch kind {
        case .squeeze:
            var text = "\(kind.shortName) \(stock.units) 支"
            if stock.partialCapacity > 0 { text += " + 剩 \(stock.partialCapacity)" }
            return text
        case .pan:
            return "\(kind.shortName) \(stock.units) 个"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ColorDot(hex: status.color.hex, size: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(status.color.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Text(status.headline)
                    .font(.caption)
                    .foregroundStyle(Theme.color(for: status.state))

                // 两种补充装分开显示。合成一个"还能补 N 格"虽然简洁，
                // 但用户没法一眼看出"我到底有没有挤出装、有没有替换装"。
                HStack(spacing: 8) {
                    ForEach(RefillKind.allCases) { kind in
                        if let text = stockText(for: kind) {
                            Label(text, systemImage: kind.symbolName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if status.color.refills.isEmpty {
                        Text("还没有登记补充装")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 8)

            StockStateBadge(state: status.state)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - 库存编辑

struct RefillStockEditorSheet: View {

    let color: PaintColor

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query private var allColors: [PaintColor]

    /// 重新从库里取一份最新的，保证关系变化后界面同步。
    private var liveColor: PaintColor {
        allColors.first { $0.code == color.code } ?? color
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        ColorDot(hex: liveColor.hex, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(liveColor.name)
                            if !liveColor.subtitle.isBlank {
                                Text(liveColor.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                squeezeSection
                panSection

                Section {
                    let status = PaletteService.status(for: liveColor)
                    InfoRow(label: "盒内占用", value: "\(liveColor.wellCount) 格")
                    InfoRow(label: "需要补", value: "\(status.needed) 格")
                    InfoRow(label: "还能补", value: "\(status.totalCapacity) 格")
                    if status.shortage > 0 {
                        InfoRow(label: "缺口", value: "\(status.shortage) 格", tint: .red)
                    }
                } header: {
                    Text("当前状况")
                } footer: {
                    Text(PaletteService.status(for: liveColor).detail)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("补充装库存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: 挤出补充装

    @ViewBuilder
    private var squeezeSection: some View {
        let stock = liveColor.refills.first { $0.kind == .squeeze }

        Section {
            IntStepper(
                value: Binding(
                    get: { stock?.units ?? 0 },
                    set: { setUnits($0, kind: .squeeze) }
                ),
                suffix: "支"
            )

            Stepper(
                "每支能补 \(stock?.capacityPerUnit ?? RefillKind.squeeze.defaultCapacityPerUnit) 格",
                value: Binding(
                    get: { stock?.capacityPerUnit ?? RefillKind.squeeze.defaultCapacityPerUnit },
                    set: { setCapacityPerUnit($0, kind: .squeeze) }
                ),
                in: 1...20
            )

            if let stock, stock.partialCapacity > 0 {
                IntStepper(
                    value: Binding(
                        get: { stock.partialCapacity },
                        set: { setPartial($0, kind: .squeeze) }
                    ),
                    suffix: "格（已开封那支还剩）"
                )
            }
        } header: {
            Label(RefillKind.squeeze.displayName, systemImage: RefillKind.squeeze.symbolName)
        } footer: {
            Text(RefillKind.squeeze.explanation
                 + (stock.map { "\n当前：\($0.capacityDescription)" } ?? "\n当前：还没有登记"))
        }
    }

    // MARK: 直接替换装

    @ViewBuilder
    private var panSection: some View {
        let stock = liveColor.refills.first { $0.kind == .pan }

        Section {
            IntStepper(
                value: Binding(
                    get: { stock?.units ?? 0 },
                    set: { setUnits($0, kind: .pan) }
                ),
                suffix: "个"
            )
        } header: {
            Label(RefillKind.pan.displayName, systemImage: RefillKind.pan.symbolName)
        } footer: {
            Text(RefillKind.pan.explanation
                 + (stock.map { "\n当前：\($0.capacityDescription)" } ?? "\n当前：还没有登记"))
        }
    }

    // MARK: 写回

    private func setUnits(_ value: Int, kind: RefillKind) {
        let existing = liveColor.refills.first { $0.kind == kind }
        PaletteService.setStock(
            units: value,
            capacityPerUnit: existing?.capacityPerUnit ?? kind.defaultCapacityPerUnit,
            partialCapacity: existing?.partialCapacity ?? 0,
            kind: kind,
            for: liveColor,
            in: context
        )
    }

    private func setCapacityPerUnit(_ value: Int, kind: RefillKind) {
        let existing = liveColor.refills.first { $0.kind == kind }
        PaletteService.setStock(
            units: existing?.units ?? 0,
            capacityPerUnit: value,
            partialCapacity: existing?.partialCapacity ?? 0,
            kind: kind,
            for: liveColor,
            in: context
        )
    }

    private func setPartial(_ value: Int, kind: RefillKind) {
        let existing = liveColor.refills.first { $0.kind == kind }
        PaletteService.setStock(
            units: existing?.units ?? 0,
            capacityPerUnit: existing?.capacityPerUnit ?? kind.defaultCapacityPerUnit,
            partialCapacity: value,
            kind: kind,
            for: liveColor,
            in: context
        )
    }
}
