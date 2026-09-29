//
//  IncomingPackageView.swift
//  ArtAssist — 美术生的工具箱
//
//  「在途」：买了什么、到货没有、入库了没有。
//
//  ── 这一页才是整个功能的落点 ─────────────────────────────────
//  淘宝订单同步、粘贴订单文本、扫面单 —— 前面那些都只是"知道有什么"。
//  真正省事的是最后一步：到货之后**一键把清单加进库存**，
//  不用一支一支去点补充装的数量。
//
//  ── 界面顺序按实际流程排 ─────────────────────────────────────
//      在途的（还没到）→ 已收到的（待入库）→ 已入库的（历史）
//  每次打开，最上面就是现在该动手的那一条。
//

import SwiftData
import SwiftUI

struct IncomingPackageView: View {

    let taobaoStore: TaobaoSessionStore

    @Environment(\.modelContext) private var context

    @Query(sort: [SortDescriptor(\IncomingPackage.createdAt, order: .reverse)])
    private var packages: [IncomingPackage]

    @State private var isAdding = false
    @State private var isShowingOrders = false
    @State private var openedPackage: IncomingPackage?
    @State private var logisticsPackage: IncomingPackage?
    @State private var message: String?
    @State private var filter: Filter = .active

    enum Filter: String, CaseIterable, Identifiable {
        case active
        case all
        case stocked

        var id: String { rawValue }
        var title: String {
            switch self {
            case .active: return "还没入库"
            case .all: return "全部"
            case .stocked: return "已入库"
            }
        }
    }

    private var visible: [IncomingPackage] {
        switch filter {
        case .active: return packages.filter { $0.status != .stocked }
        case .all: return packages
        case .stocked: return packages.filter { $0.status == .stocked }
        }
    }

    private var receivedCount: Int {
        packages.filter { $0.status == .received }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if receivedCount > 0 {
                NoticeBanner(
                    level: .warning,
                    title: "\(receivedCount) 个包裹已到货、还没入库",
                    message: "点开那一条，点「入库」就把清单加进库存了。"
                )
            }

            if packages.isEmpty {
                emptyCard
            } else {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                if visible.isEmpty {
                    NoticeBanner(level: .success,
                                 title: filter == .stocked ? "还没有入库记录" : "都入库了",
                                 message: filter == .stocked
                                     ? "入库过的包裹会出现在这里。"
                                     : "没有待收的包裹。")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, package in
                            Button {
                                openedPackage = package
                            } label: {
                                packageRow(package)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if !package.trackingNumber.isEmpty {
                                    Button {
                                        logisticsPackage = package
                                    } label: {
                                        Label("查看物流", systemImage: "map")
                                    }
                                }
                                if package.status == .inTransit {
                                    Button {
                                        IncomingPackageService.markReceived(package, in: context)
                                        Haptics.saved()
                                    } label: {
                                        Label("标记为已收到", systemImage: "tray.and.arrow.down")
                                    }
                                }
                                if package.status == .received {
                                    Button {
                                        let outcome = IncomingPackageService.stock(package, in: context)
                                        Haptics.saved()
                                        message = outcome.summary
                                    } label: {
                                        Label("入库", systemImage: "checkmark.seal")
                                    }
                                }
                                Divider()
                                Button(role: .destructive) {
                                    IncomingPackageService.delete(package, in: context)
                                    Haptics.alert()
                                } label: {
                                    Label("删除这个包裹", systemImage: "trash")
                                }
                            }

                            if index < visible.count - 1 {
                                Divider().padding(.leading, 56)
                            }
                        }
                    }
                    .cardStyle(padding: 8)
                }
            }

            addButtons
        }
        .sheet(isPresented: $isAdding) {
            IncomingPackageEditorView(taobaoStore: taobaoStore) { package in
                openedPackage = package
            }
        }
        .sheet(isPresented: $isShowingOrders) {
            TaobaoOrdersView(store: taobaoStore)
        }
        .sheet(item: $openedPackage) { package in
            IncomingPackageDetailView(package: package)
        }
        .sheet(item: $logisticsPackage) { package in
            LogisticsQueryView(
                trackingNumber: package.trackingNumber,
                carrierName: package.carrierDisplay == "承运商未知"
                    ? ""
                    : package.carrierName
            )
        }
        .alert("提示", isPresented: .presentWhen($message)) {
            Button("好") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: - 空状态

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("还没有待收包裹", systemImage: "shippingbox")
                .font(.headline)
            Text("记下「这单买了什么」，到货时一键加进库存 —— 不用一支一支去点数量。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("来源有两种：**粘贴订单文字**（淘宝订单页复制出来的、或快递短信），"
                 + "或者**从淘宝同步订单**。前者完全离线，后者需要登录。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var addButtons: some View {
        VStack(spacing: 10) {
            Button {
                isAdding = true
            } label: {
                Label("粘贴订单文字 / 扫面单", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .artProminentButton()
            .controlSize(.large)

            Button {
                isShowingOrders = true
            } label: {
                Label(taobaoStore.isLoggedIn ? "从淘宝同步订单" : "登录淘宝并同步订单",
                      systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .artGlassButton()
            .controlSize(.large)
        }
    }

    // MARK: - 一行

    private func packageRow(_ package: IncomingPackage) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: package.status.symbolName)
                .font(.callout)
                .foregroundStyle(tint(for: package.status))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(package.trackingDisplay)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(package.status.displayName)
                        .font(.caption2)
                        .foregroundStyle(tint(for: package.status))
                    Text(package.carrierDisplay)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if package.status != .stocked {
                        Text(package.arrivalText)
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if !package.taobaoOrderID.isEmpty {
                        Label("淘宝", systemImage: "cart")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if !package.items.isEmpty {
                    Text(package.items.prefix(2).map(\.name).joined(separator: "、")
                         + (package.items.count > 2 ? " 等 \(package.items.count) 件" : ""))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private func tint(for status: IncomingPackageStatus) -> Color {
        switch status {
        case .inTransit: return .secondary
        case .received: return .orange
        case .stocked: return .green
        }
    }
}

// MARK: - 新增：粘贴 / 扫面单

struct IncomingPackageEditorView: View {

    let taobaoStore: TaobaoSessionStore
    var onCreated: (IncomingPackage) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var manualTracking = ""
    @State private var isShowingScanner = false
    @State private var preview: ParsedOrderText?
    @State private var matched: [MatchedPackageItem] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    inputCard
                    if let preview { previewCard(preview) }
                }
                .padding(20)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .artScrollEdgeEffect()
            .navigationTitle("新增待收包裹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { create() }
                        .disabled(text.isBlank && manualTracking.isBlank)
                        .fontWeight(.semibold)
                }
            }
            .fullScreenCover(isPresented: $isShowingScanner) {
                // 复用扫码页：快递面单上是 Code128 条码
                PaintScanView()
            }
            .onChange(of: text) { _, _ in refreshPreview() }
            .onChange(of: manualTracking) { _, _ in refreshPreview() }
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "订单文字", subtitle: "从淘宝订单页复制，或粘贴快递短信")

            TextField(
                "把订单文字粘在这里。例如：\n马利水粉补充装 群青 5ml x2\n钛白替换装 x1\n快递单号 SF1234567890123",
                text: $text,
                axis: .vertical
            )
            .lineLimit(5...12)
            .textFieldStyle(.plain)
            .font(.callout)

            HStack(spacing: 12) {
                TextField("或直接填快递单号", text: $manualTracking)
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .autocorrectionDisabled()
                    .onSubmit { refreshPreview() }

                Button {
                    if let clip = UIPasteboard.general.string, !clip.isEmpty {
                        if text.isBlank { text = clip } else { text += "\n" + clip }
                        Haptics.saved()
                    }
                } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("解析完全在本机做。商品名会自动匹配你颜色库里已有的颜色与耗材 —— "
                 + "匹配不上也不会瞎猜，入库时你再选。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func previewCard(_ parsed: ParsedOrderText) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "解析结果",
                subtitle: "\(matched.count) 条商品"
                    + (parsed.trackingNumber.map { " · 单号 \($0)" } ?? " · 没找到单号")
            )

            if let tracking = parsed.trackingNumber {
                HStack(spacing: 8) {
                    Label(tracking, systemImage: "shippingbox")
                        .font(.system(.caption, design: .monospaced))
                    if let carrier = parsed.carrier {
                        Text(carrier)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if matched.isEmpty {
                Text("没解析出商品。订单文字里要有商品名（比如「群青补充装 x2」）。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(matched.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Text(item.item.name)
                                    .font(.caption)
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                                Text("×\(item.item.quantity)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 6) {
                                Text(item.target.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(item.target == .unmatched ? Color.secondary : Theme.accent)
                                if item.needsConfirmation, item.target != .unmatched {
                                    Text("（可能不准）")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                        .padding(.vertical, 6)

                        if index < matched.count - 1 { Divider() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func refreshPreview() {
        let combined = text.isBlank ? manualTracking : text
        guard !combined.isBlank else {
            preview = nil
            matched = []
            return
        }
        let parsed = OrderTextParser.parse(
            combined,
            preferTracking: manualTracking.isBlank ? nil : manualTracking.trimmed
        )
        preview = parsed
        matched = PackageItemMatcher.match(
            items: parsed.items,
            against: IncomingPackageService.catalog(in: context)
        )
    }

    private func create() {
        let combined = text.isBlank ? manualTracking : text
        let catalog = IncomingPackageService.catalog(in: context)
        let package = IncomingPackageService.create(
            from: combined,
            catalog: catalog,
            preferTracking: manualTracking.isBlank ? nil : manualTracking.trimmed,
            in: context
        )
        Haptics.saved()
        onCreated(package)
        dismiss()
    }
}

// MARK: - 详情：入库

struct IncomingPackageDetailView: View {

    let package: IncomingPackage

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var message: String?
    @State private var isConfirmingDelete = false
    @State private var isShowingLogistics = false
    /// 单独的提示：`message` 那个 alert 标题是"入库结果"，
    /// 拿来显示"推算不了"会张冠李戴。
    @State private var arrivalNote: String?

    private var items: [IncomingPackageItem] { package.orderedItems }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerCard
                    arrivalCard
                    itemsCard
                    if let raw = package.sourceRaw.nilIfBlank, !raw.isEmpty { sourceCard(raw) }
                    actionCard
                }
                .padding(20)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .artScrollEdgeEffect()
            .navigationTitle("待收包裹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("入库结果", isPresented: .presentWhen($message)) {
                Button("好") { message = nil }
            } message: {
                Text(message ?? "")
            }
            .sheet(isPresented: $isShowingLogistics) {
                LogisticsQueryView(
                    trackingNumber: package.trackingNumber,
                    carrierName: package.carrierDisplay == "承运商未知"
                        ? ""
                        : package.carrierName
                )
            }
            .alert("到货推算", isPresented: .presentWhen($arrivalNote)) {
                Button("好") { arrivalNote = nil }
            } message: {
                Text(arrivalNote ?? "")
            }
            .confirmationDialog("删除这个包裹？", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    IncomingPackageService.delete(package, in: context)
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("只删这条记录，已经入进库存的数量不受影响。")
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: package.status.symbolName)
                    .font(.title2)
                    .foregroundStyle(package.status == .stocked ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(package.trackingDisplay)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text(package.carrierDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(package.status.displayName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        (package.status == .stocked ? Color.green : Color.orange).opacity(0.15),
                        in: Capsule()
                    )
            }

            if !package.taobaoOrderID.isEmpty {
                Text("淘宝订单号 \(package.taobaoOrderID)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - 预计到达

    /// 预计到达时间的编辑。
    ///
    /// 这一块是「正在补货中 · 多久能到」的输入与展示：
    ///   · 显示当前的到达文案与来源（你填的 / 按历史推算 / 默认估的）
    ///   · 日期选择器直接改
    ///   · 快捷按钮按今天推（明天 / 2 天后 / 3 天后 / 一周后）
    ///   · 「按历史推算」重算这家快递的历史中位数
    ///
    /// ⚠️ 刻意不内置"顺丰 1 天、中通 3 天"这种表 —— 那是编的，
    ///    而且各条线路差别很大。要么用**你自己的历史**，要么你自己填。
    private var arrivalCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: "预计到达",
                subtitle: package.arrivalText
            )

            HStack(spacing: 8) {
                Text(package.arrivalSource.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        (package.arrivalSource == .user ? Theme.accent : Color.gray).opacity(0.14),
                        in: Capsule()
                    )
                    .foregroundStyle(package.arrivalSource == .user ? Theme.accent : .secondary)
                Spacer(minLength: 0)
            }

            DatePicker(
                "到达日期",
                selection: Binding(
                    get: { package.estimatedArrival ?? Date.now },
                    set: { date in
                        IncomingPackageService.setArrival(date, for: package, in: context)
                        Haptics.selection()
                    }
                ),
                displayedComponents: .date
            )
            .datePickerStyle(.compact)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([1, 2, 3, 7], id: \.self) { days in
                        Button(days == 1 ? "明天" : "\(days) 天后") {
                            let date = Calendar.current.date(
                                byAdding: .day, value: days, to: Date.now
                            ) ?? Date.now
                            IncomingPackageService.setArrival(date, for: package, in: context)
                            Haptics.selection()
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button("按历史推算") {
                        let estimate = IncomingPackageService.estimateArrival(
                            for: package.carrierName,
                            createdFrom: package.orderedAt ?? package.createdAt,
                            in: context
                        )
                        if let date = estimate.date {
                            package.estimatedArrival = date
                            package.arrivalSource = estimate.source
                            try? context.save()
                            Haptics.selection()
                        } else {
                            // 没有历史就**不要**编一个日期出来，直接说实话
                            Haptics.alert()
                            arrivalNote = "这家快递还没有两次以上的到货记录，推算不了。"
                                + "用上面的日期或快捷按钮直接填，填两次之后就有的推了。"
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if package.estimatedArrival != nil {
                Button("清除预计到达", role: .destructive) {
                    IncomingPackageService.setArrival(nil, for: package, in: context)
                }
                .font(.caption2)
            }

            Text("有两次以上到货记录时，会按这家快递过去几次的实际天数取中位数；"
                 + "没有就不猜，等你填。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var itemsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "清单",
                subtitle: "\(items.count) 条 · \(package.matchedCount) 条匹配到库里的东西"
            )

            if items.isEmpty {
                Text("这个包裹没有商品清单（只记了单号）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        itemRow(item)
                        if index < items.count - 1 { Divider() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func itemRow(_ item: IncomingPackageItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(item.name)
                    .font(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if item.isStocked {
                    Label("已入库", systemImage: "checkmark.seal.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            Text(item.targetDisplay)
                .font(.caption2)
                .foregroundStyle(item.matched ? Theme.accent : Color.secondary)

            HStack(spacing: 10) {
                Text("应有")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                IntStepper(
                    value: Binding(
                        get: { item.quantity },
                        set: { item.quantity = max(0, $0); try? context.save() }
                    ),
                    suffix: "件"
                )

                if !item.isStocked, item.matched {
                    Text("实收")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    IntStepper(
                        value: Binding(
                            get: { item.stockedQuantity > 0 ? item.stockedQuantity : item.quantity },
                            set: { item.stockedQuantity = max(0, $0); try? context.save() }
                        ),
                        suffix: "件"
                    )
                }
            }

            // 类型没定的颜料条目不让人入库 —— 加错地方比不加更糟
            if item.targetKindRaw == "color", item.refillKind == nil, !item.isStocked {
                HStack(spacing: 8) {
                    Text("是哪种补充装？")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    ForEach(RefillKind.allCases) { kind in
                        Button(kind.shortName) {
                            item.refillKind = kind
                            try? context.save()
                            Haptics.selection()
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func sourceCard(_ raw: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "来源原文")
            Text(raw)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !package.trackingNumber.isEmpty {
                Button {
                    isShowingLogistics = true
                } label: {
                    Label("查看物流", systemImage: "map")
                        .frame(maxWidth: .infinity)
                }
                .artGlassButton()
                .controlSize(.large)
            }

            if package.status == .inTransit {
                Button {
                    IncomingPackageService.markReceived(package, in: context)
                    Haptics.saved()
                } label: {
                    Label("已收到", systemImage: "tray.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .artProminentButton()
                .controlSize(.large)
            }

            // 入库按钮对任何状态都可用：只处理"还没入库"的条目，
            // 所以到货后可以分几次入库（比如先到了一部分）。
            Button {
                let outcome = IncomingPackageService.stock(package, in: context)
                Haptics.saved()
                message = outcome.summary
                    + (outcome.messages.isEmpty
                       ? "" : "\n\n" + outcome.messages.joined(separator: "\n"))
            } label: {
                Label(
                    package.status == .stocked ? "再入库一次（只处理未入库的）" : "入库",
                    systemImage: "checkmark.seal"
                )
                .frame(maxWidth: .infinity)
            }
            .artProminentButton()
            .controlSize(.large)
            .disabled(items.isEmpty || items.allSatisfy(\.isStocked))

            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("删除这个包裹", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .artGlassButton()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}
