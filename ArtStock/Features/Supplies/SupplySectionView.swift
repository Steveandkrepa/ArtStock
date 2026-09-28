//
//  SupplySectionView.swift
//  ArtAssist — 美术生的工具箱
//
//  其他耗材（纸、笔、橡皮、胶带）。**卡片网格 + 就地快调。**
//
//  ── 为什么要重做 ─────────────────────────────────────────────
//  真实反馈：「其他耗材管理要重构，太反人类，应该要和颜料盒一样」。
//
//  原来那一版确实反人类，具体反在哪：
//    1. 改一个数量要点四次：点行 → 弹出表单 → 找到「还剩」→ 点数字 →
//       数字键盘 → 保存。而颜料盒那边是**点一下 → 五个大按钮 → 完事**。
//    2. 只有一个数字（"3 张"），没有"这是多还是少"的参照。
//       颜料盒有余量条，一眼看得出哪几格空。
//    3. 行是纯文字列表，一屏看不了几项，也没法扫视。
//    4. **单位是个三选一的菜单**，想填「毫升」「米」根本没门路；
//       而且换分类时会**悄悄改掉你已经填好的单位** —— 这条尤其气人。
//
//  现在：
//    · 卡片网格，每张卡一条**余量条**（跟颜料盒同一套语言）
//    · 点卡片 → 大按钮快调（用完 / 补满 / 加减 / 滑一下），不用键盘
//    · 单位**自由输入 + 常用项快捷**，不再锁死三选一
//    · 新增「满量」字段，设了才有真正的比例；换分类绝不覆盖单位
//    · 快用完的排在各分类最前面
//
//  这一块是嵌在「库存与采购」里的内容，没有 navigationTitle，
//  也不用 List（嵌在 ScrollView 里），分组卡片自己撑起来。
//

import SwiftData
import SwiftUI

struct SupplySectionView: View {

    @Environment(\.modelContext) private var context

    @Query(sort: [SortDescriptor(\SupplyItem.categoryRaw), SortDescriptor(\SupplyItem.name)])
    private var items: [SupplyItem]

    @State private var quickItem: SupplyItem?
    @State private var editingItem: SupplyItem?
    @State private var isAddingItem = false

    /// 按分类分组的卡片。空分类不显示。
    private var grouped: [(category: SupplyCategory, items: [SupplyItem])] {
        Dictionary(grouping: items, by: { $0.category })
            .map { (category: $0.key, items: $0.value.sorted {
                // 快用完的排前面 —— 这个 App 的存在意义就是"先看要动手的"
                if $0.level.needsAttention != $1.level.needsAttention {
                    return $0.level.needsAttention
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }) }
            .sorted { $0.category.sortOrder < $1.category.sortOrder }
    }

    private var attentionCount: Int {
        items.filter { $0.level.needsAttention }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if items.isEmpty {
                emptyCard
            } else {
                if attentionCount > 0 {
                    NoticeBanner(
                        level: .warning,
                        title: "\(attentionCount) 项快用完了",
                        message: "点卡片改数量，可一键归零。"
                    )
                }

                ForEach(grouped, id: \.category) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        SectionHeader(
                            title: group.category.displayName,
                            subtitle: "\(group.items.count) 项"
                        )

                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 152), spacing: 12)],
                            spacing: 12
                        ) {
                            ForEach(group.items) { item in
                                Button {
                                    quickItem = item
                                    Haptics.selection()
                                } label: {
                                    SupplyCard(
                                        item: item,
                                        incomingQuantity: IncomingPackageService
                                            .incomingQuantity(forSupply: item.name, in: context)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()
                }

                Button {
                    isAddingItem = true
                } label: {
                    Label("添加耗材", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .artGlassButton()
                .controlSize(.large)
            }
        }
        .sheet(item: $quickItem) { item in
            SupplyQuickSheet(item: item) {
                editingItem = item
            }
        }
        .sheet(item: $editingItem) { item in
            SupplyEditorSheet(item: item)
        }
        .sheet(isPresented: $isAddingItem) {
            SupplyEditorSheet(item: nil)
        }
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("还没有登记其他耗材", systemImage: "square.grid.2x2")
                .font(.headline)
            Text("纸、笔、橡皮这些也可以记一下 —— 记了就会跟颜料一起出现在上面的采购结论里，"
                 + "快用完时也会算进去。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                isAddingItem = true
            } label: {
                Label("添加第一项", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .artProminentButton()
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// MARK: - 卡片

/// 一项耗材的卡片。跟颜料盒的格子是同一套视觉语言：**主体是余量，不是文字**。
private struct SupplyCard: View {

    let item: SupplyItem
    /// 在途件数。由外层传入（外层有 modelContext，这里保持轻量不 fetch）。
    var incomingQuantity: Double = 0
    var incomingQuantityText: String {
        incomingQuantity == incomingQuantity.rounded()
            ? String(Int(incomingQuantity))
            : String(format: "%.1f", incomingQuantity)
    }

    private var tint: Color {
        switch item.level {
        case .out: return .red
        case .low: return .orange
        case .half: return .yellow
        case .okay: return .green
        case .plenty: return Theme.accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.category.symbolName)
                    .font(.caption)
                    .foregroundStyle(tint)
                    .frame(width: 18)

                Text(item.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }

            // 余量条：这一块是卡片的主角
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(uiColor: .tertiarySystemFill))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, geometry.size.width * item.barFraction))
                }
            }
            .frame(height: 8)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.quantityText)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(item.level.needsAttention ? tint : .primary)
                    .contentTransition(.numericText())

                Spacer(minLength: 0)

                Text(item.level.displayName)
                    .font(.caption2)
                    .foregroundStyle(item.level.needsAttention ? tint : .secondary)
            }

            if !item.hasFullCapacity {
                Text("可设「满量」以获得比例")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if incomingQuantity > 0 {
                Label("在途 \(incomingQuantityText) \(item.unit)", systemImage: "shippingbox")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    item.level.needsAttention ? tint.opacity(0.45) : Color.clear,
                    lineWidth: 1.5
                )
        )
        .contentShape(Rectangle())
    }
}

// MARK: - 快调面板

/// 点卡片之后弹出来的。
///
/// 设计目标：**改数量不碰键盘**。
/// 所以是「用完」/「补满」大按钮 + 加减步进 + 一个滑块，改完直接关。
/// 名称、单位、提醒线这些低频的东西全部收进「编辑资料」二级页。
struct SupplyQuickSheet: View {

    let item: SupplyItem
    /// 进二级页编辑资料。
    var onEdit: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var draftQuantity: Double = 0
    @State private var draftFull: Double = 0
    @State private var didLoad = false
    /// 正在用键盘直接输入数量。
    @State private var isEditingQuantity = false
    @State private var quantityText = ""
    @FocusState private var quantityFocused: Bool
    /// 滑块上界（打开这一页时定死，见 `load()`）。
    @State private var sliderCeiling: Double = 10

    /// 加减步长：**统一 1**。
    ///
    /// ⚠️ 原来这里是"纸张 5、其余 1"——一个按分类偷偷变化的步长。
    ///    用户根本不知道按一下会动多少，纸张想减 1 张也做不到，
    ///    这就是"数量控制一团糟"的一部分。
    ///    现在：加减永远动 1（可预期），要大范围动就用滑块，
    ///    要精确就点数字直接打字。
    private var step: Double { 1 }

    /// 滑块的上界：设了满量就用满量，否则用打开时定下的那个值。
    private var sliderMax: Double {
        draftFull > 0 ? max(draftFull, 1) : sliderCeiling
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    quantityCard
                    capacityCard
                    editCard
                }
                .padding(20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .artScrollEdgeEffect()
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { commitAndClose() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear(perform: load)
        .onDisappear(perform: commit)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: item.category.symbolName)
                .font(.title2)
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accent.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(item.category.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(levelText)
                    .font(.headline)
            }

            Spacer(minLength: 0)
        }
        .cardStyle()
    }

    private var levelText: String {
        StockPlan.level(
            quantity: draftQuantity, fullCapacity: draftFull, lowThreshold: item.lowThreshold
        ).displayName
    }

    private var quantityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "还剩多少", subtitle: "点数字可以直接打字，也可以用加减/滑块")

            HStack(alignment: .center, spacing: 14) {
                Button {
                    draftQuantity = max(0, draftQuantity - step)
                    Haptics.selection()
                } label: {
                    Image(systemName: "minus")
                        .font(.title2.weight(.semibold))
                        .frame(width: 56, height: 56)
                        .artGlassCircle()
                }
                .disabled(draftQuantity <= 0)

                VStack(spacing: 2) {
                    // ⚠️ 这个数字**必须是可输入的**。
                    //    原来是一块死文字，副标题还写着"不用打字"——
                    //    想从 37 张改成 36 张只有按减号这一条路（纸张一次 5 张，
                    //    连 1 都减不了）。这就是"数量控制一团糟"的核心。
                    if isEditingQuantity {
                        TextField("0", text: $quantityText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.center)
                            .font(.system(size: 44, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .focused($quantityFocused)
                            .frame(maxWidth: 220)
                            .onSubmit { commitQuantityText() }
                            .onChange(of: quantityFocused) { _, focused in
                                if !focused { commitQuantityText() }
                            }
                    } else {
                        Button {
                            beginEditingQuantity()
                        } label: {
                            Text(displayQuantity)
                                .font(.system(size: 44, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .minimumScaleFactor(0.5)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("还剩 \(displayQuantity) \(item.unit)，点一下可输入")
                    }

                    Text(isEditingQuantity ? "输入后点空白处生效" : item.unit)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                Button {
                    draftQuantity += step
                    Haptics.selection()
                } label: {
                    Image(systemName: "plus")
                        .font(.title2.weight(.semibold))
                        .frame(width: 56, height: 56)
                        .artGlassCircle()
                }
            }

            Slider(value: $draftQuantity, in: 0...max(1, sliderMax),
                   step: sliderStep)
                .tint(Theme.accent)

            HStack(spacing: 10) {
                Button {
                    draftQuantity = 0
                    Haptics.saved()
                } label: {
                    Label("用完了", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .artGlassButton()
                .controlSize(.large)
                .disabled(draftQuantity == 0)

                Button {
                    draftQuantity = draftFull > 0 ? draftFull : draftQuantity + step * 5
                    Haptics.saved()
                } label: {
                    Label(draftFull > 0 ? "补满了" : "买了一包",
                          systemImage: "arrow.up.to.line")
                        .frame(maxWidth: .infinity)
                }
                .artGlassButton()
                .controlSize(.large)
            }

            Text("加减按钮每次 \(String(format: "%g", step)) \(item.unit)"
                 + (isEditingQuantity ? "。" : "；想精确到个位就点上面的数字直接填。"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// 滑块步长。
    ///
    /// 单位是"张/克/毫升"这种可以有小数的就按 0.5，整数单位按 1 ——
    /// 原来固定按 1，于是「2.5 米」这种值滑块根本给不出来。
    private var sliderStep: Double {
        item.quantity.rounded() == item.quantity ? 1 : 0.5
    }

    private func beginEditingQuantity() {
        quantityText = displayQuantity
        isEditingQuantity = true
        quantityFocused = true
    }

    /// 提交手输的数字。
    ///
    /// 解析失败（空、只有一个点、写了字）就保持原值 —— 不能把用户
    /// 原来的数量抹成 0。
    private func commitQuantityText() {
        let cleaned = quantityText
            .replacingOccurrences(of: "，", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Double(cleaned), value.isFinite {
            draftQuantity = max(0, value)
        }
        isEditingQuantity = false
        quantityFocused = false
    }

    /// 大数字显示：整数不显示小数点。
    private var displayQuantity: String {
        let rounded = draftQuantity.rounded()
        if abs(draftQuantity - rounded) < 0.0001 {
            return String(Int(rounded))
        }
        return String(format: "%.1f", draftQuantity)
    }

    private var capacityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "满量",
                subtitle: draftFull > 0 ? "余量条按这个算比例" : "设了才有比例，不设也能用"
            )

            HStack(spacing: 12) {
                Text("满的时候有")
                    .font(.subheadline)
                Spacer(minLength: 0)
                DoubleStepper(value: $draftFull, step: step, suffix: item.unit)
            }

            Text(draftFull > 0
                 ? "现在还剩 \(Int((min(1, draftQuantity / max(1, draftFull)) * 100).rounded()))%。"
                 : "不填也能用，只是卡片上没有精确比例。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var editCard: some View {
        Button {
            commit()
            onEdit()
            dismiss()
        } label: {
            Label("编辑资料（名称 / 单位 / 提醒线）", systemImage: "slider.horizontal.3")
                .frame(maxWidth: .infinity)
        }
        .artGlassButton()
        .controlSize(.large)
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        draftQuantity = item.quantity
        draftFull = item.fullCapacity
        // ⚠️ 滑块上界在这里**定死**。原来它是 `max(10, draftQuantity * 1.5)`，
        //    也就是"上界跟着被它控制的值跑" —— 拖动时上界一起变，
        //    同一根手指位置对应的数值一直在跳，手感就是"数量乱跳、控制不住"。
        sliderCeiling = max(10, (item.quantity * 1.5).rounded(.up))
    }

    private func commit() {
        item.quantity = max(0, draftQuantity)
        item.fullCapacity = max(0, draftFull)
        item.updatedAt = .now
        try? context.save()
    }

    private func commitAndClose() {
        commit()
        Haptics.saved()
        dismiss()
    }
}

// MARK: - 编辑资料

struct SupplyEditorSheet: View {

    /// nil 表示新建。
    let item: SupplyItem?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var category: SupplyCategory = .paper
    @State private var quantity: Double = 0
    @State private var unit = ""
    @State private var lowThreshold: Double = 0
    @State private var fullCapacity: Double = 0
    @State private var note = ""

    private var isEditing: Bool { item != nil }

    /// 单位建议。
    ///
    /// ⚠️ 这是**建议**，不是白名单 —— 原来是个三选一的菜单，
    /// 想填「毫升」「米」根本没门路。现在下面有自由输入框，
    /// 这里只是几个点一下就填上的常用项。
    private var unitSuggestions: [String] {
        var list: [String]
        switch category {
        case .paper: list = ["张", "本", "卷", "包"]
        case .brush: list = ["支", "套", "盒"]
        case .eraser: list = ["块", "个", "盒"]
        case .tape: list = ["卷", "个", "米"]
        case .other: list = ["个", "包", "盒", "瓶", "毫升", "克", "米"]
        }
        // 用户自己用过的单位排前面
        if let item {
            for recent in item.recentUnits.reversed() where !list.contains(recent) {
                list.insert(recent, at: 0)
            }
        }
        return list
    }

    /// 加减步长：统一 1（和快速改数量那一页保持一致，可预期）。
    /// 大范围用不着在这儿按 —— 右边的输入框可以直接打字。
    private var step: Double { 1 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称，如「4K 素描纸」", text: $name)

                    Picker("分类", selection: $category) {
                        ForEach(SupplyCategory.allCases) { category in
                            Label(category.displayName, systemImage: category.symbolName)
                                .tag(category)
                        }
                    }
                    // ⚠️ 刻意**不**在这里改单位。
                    //    原来换分类会把用户填好的单位悄悄改掉（"米"变成"张"），
                    //    这是最招人烦的一处。现在只在单位还空着时给个建议。
                    .onChange(of: category) { _, _ in
                        if unit.trimmed.isEmpty {
                            unit = unitSuggestions.first ?? "个"
                        }
                    }
                }

                Section {
                    TextField("单位，可自由填写", text: $unit)
                        .autocorrectionDisabled()

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(unitSuggestions, id: \.self) { suggestion in
                                Button {
                                    unit = suggestion
                                    Haptics.selection()
                                } label: {
                                    Text(suggestion)
                                        .font(.caption)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            unit == suggestion
                                            ? Theme.accent.opacity(0.2)
                                            : Color(uiColor: .tertiarySystemFill),
                                            in: Capsule()
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } header: {
                    Text("单位")
                } footer: {
                    Text("想写「毫升」「米」「克」都行。用过的会出现在上面。")
                }

                Section {
                    HStack(spacing: 12) {
                        Text("还剩")
                        Spacer(minLength: 0)
                        DoubleStepper(value: $quantity, step: step,
                                      suffix: unit.trimmed.isEmpty ? "" : unit.trimmed)
                    }
                    HStack(spacing: 12) {
                        Text("满的时候有")
                        Spacer(minLength: 0)
                        DoubleStepper(value: $fullCapacity, step: step,
                                      suffix: unit.trimmed.isEmpty ? "" : unit.trimmed)
                    }
                } header: {
                    Text("数量")
                } footer: {
                    Text(fullCapacity > 0
                         ? "卡片上的余量条按「还剩 ÷ 满量」画。"
                         : "「满的时候有」不填也行，只是卡片上就没有精确比例。")
                }

                Section {
                    HStack(spacing: 12) {
                        Text("低于")
                        Spacer(minLength: 0)
                        DoubleStepper(value: $lowThreshold, step: step,
                                      suffix: unit.trimmed.isEmpty ? "" : unit.trimmed)
                    }
                } header: {
                    Text("提醒线")
                } footer: {
                    Text(lowThreshold > 0
                         ? "数量降到 \(Fmt.number(lowThreshold)) \(unit.trimmed.isEmpty ? "个" : unit.trimmed) 或以下时，会计入「库存与采购」的采购建议。"
                         : "填 0 表示只在完全用完时才算进采购建议。")
                }

                Section("备注") {
                    TextField("选填", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            if let item {
                                context.delete(item)
                                try? context.save()
                            }
                            dismiss()
                        } label: {
                            Label("删除这一项", systemImage: "trash")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "编辑耗材" : "添加耗材")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(name.isBlank)
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear(perform: load)
    }

    private func load() {
        guard let item else {
            // 新建时给一个合理的默认单位
            unit = unitSuggestions.first ?? "个"
            return
        }
        name = item.name
        category = item.category
        quantity = item.quantity
        unit = item.unit
        lowThreshold = item.lowThreshold
        fullCapacity = item.fullCapacity
        note = item.note
    }

    private func save() {
        let trimmed = name.trimmed
        guard !trimmed.isEmpty else { return }
        let finalUnit = unit.trimmed.isEmpty ? "个" : unit.trimmed

        if let item {
            item.name = trimmed
            item.category = category
            item.quantity = max(0, quantity)
            item.unit = finalUnit
            item.lowThreshold = max(0, lowThreshold)
            item.fullCapacity = max(0, fullCapacity)
            item.note = note.trimmed
            item.rememberUnit(finalUnit)
            item.updatedAt = .now
        } else {
            let created = SupplyItem(
                name: trimmed,
                category: category,
                quantity: quantity,
                unit: finalUnit,
                lowThreshold: lowThreshold,
                fullCapacity: fullCapacity > 0 ? fullCapacity : nil,
                note: note.trimmed
            )
            created.rememberUnit(finalUnit)
            context.insert(created)
        }

        try? context.save()
        Haptics.saved()
        dismiss()
    }
}

// MARK: - 小数步进器

/// 支持小数的步进器（`Stepper` 只吃整数）。
///
/// 耗材里有「2.5 卷胶带」「还剩半瓶」这种，整数步进不够用。
struct DoubleStepper: View {

    @Binding var value: Double
    var step: Double = 1
    var suffix: String = ""

    private var display: String {
        let rounded = value.rounded()
        let text = abs(value - rounded) < 0.0001
            ? String(Int(rounded))
            : String(format: "%.1f", value)
        return suffix.isEmpty ? text : "\(text) \(suffix)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                value = max(0, value - step)
                Haptics.selection()
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .disabled(value <= 0)

            TextField("0", value: $value, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .frame(width: 74)
                .textFieldStyle(.plain)

            Button {
                value += step
                Haptics.selection()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.borderless)

            if !suffix.isEmpty {
                Text(suffix)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
        .accessibilityValue(display)
    }
}
