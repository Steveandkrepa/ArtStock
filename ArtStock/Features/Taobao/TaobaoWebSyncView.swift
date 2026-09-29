//
//  TaobaoWebSyncView.swift
//  ArtAssist — 美术生的工具箱
//
//  网页同步订单：**打开真实的淘宝订单页，你翻到哪一屏，就认哪一屏。**
//
//  ── 这里换过两次做法，原因都值得留着 ─────────────────────────
//  ① 最早是"注入脚本 hook 页面的 XMLHttpRequest/fetch 偷响应"。
//     想法是不用猜接口名，但**实际是错的**：全局 hook 破坏页面自身交互
//     （用户根本操作不了网页），而且只能拿到"刚好发生了的"请求。
//  ② 改成"截图 → OCR 认字"。方向对了，但第一版有两个具体毛病，
//     都是用户实测反馈出来的：
//       · **点不进订单详情页** —— WKWebView 默认忽略 `target="_blank"`
//         与 `window.open`，而淘宝订单卡的"查看详情"正是这种链接，
//         点了毫无反应。另外我的 user agent 写得不完整，页面可能被
//         降级成非触摸友好的版本。
//       · **认出一大堆别的东西** —— 整屏文字直接丢给解析器，
//         导航、价格、日期、"猜你喜欢"全进来了。
//     这一版就是修这两件事（见下面两段注释）。
//
//  ── 怎么让它"点得进去" ──────────────────────────────────────
//  · 实现 `WKUIDelegate`，把 `createWebViewWith`（新窗口/新标签）里的
//    请求**放回当前 WebView 加载** —— 这是"点了没反应"的根因；
//  · `javaScriptCanOpenWindowsAutomatically = true`；
//  · 补上 JS 弹窗（alert/confirm/prompt）的处理器，否则页面脚本会卡住；
//  · 用**标准 iPad Safari UA**，别自己拼一个残缺的；
//  · 加前进/后退/刷新按钮，进得去也要出得来。
//
//  ── 怎么让它"认得更准" ──────────────────────────────────────
//  · 截图按 **2 倍宽度**渲染：网页小字像素更多，OCR 明显更准；
//  · 灰度 + 提对比度后再认（彩色背景上的白字最容易认错）；
//  · 把**用户库里已有的东西**（耗材名、颜色名、色号）作为 `customWords`
//    交给 Vision —— 这些词的召回与拼写会显著变好；
//  · 调小最小文字高度（默认值是为包装上的大字设的，网页小字会被整行丢掉）；
//  · 认完再用 `TaobaoScreenFocus` 把页面框架词挤掉、把形近字纠回正确写法。
//

import CoreImage
import SwiftData
import SwiftUI
import WebKit

struct TaobaoWebSyncView: View {

    let store: TaobaoSessionStore
    /// 用户确认后回传识别到的文字。
    var onFinish: (String) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// 截图认字的引擎（Vision `.accurate` + 中文语言纠正）。
    @State private var ocr = LabelOCRService()
    @State private var holder = TaobaoWebViewHolder()
    @State private var recognizedText = ""
    @State private var lineCount = 0
    @State private var isRecognizing = false
    @State private var statusText = "翻到订单那一页，点「识别这一屏」"
    @State private var isShowingText = false
    /// 这一屏里对上了库里几样东西（给用户一个"认准了"的信号）。
    @State private var matchedCount = 0
    /// 被当成页面框架丢掉的行数。
    @State private var droppedCount = 0

    /// 词条勾选：从识别文字里再解析出来的"单号 + 商品"候选。
    @State private var review: CaptureReview?
    /// 用户勾选了哪几条商品（按 `ParsedPackageItem.id`）。
    @State private var selectedItemIDs: Set<String> = []
    /// 用户勾选了哪个快递单号。
    @State private var selectedTrackingID: String?
    /// 是否在展示「选词条建包裹」页。
    @State private var isShowingReview = false

    private let orderPage = TaobaoWebEndpoint.orderListPage

    /// 灰度 + 提对比度用的共享 CIContext。
    ///
    /// 每次新建 CIContext 都要重新编译 GPU 管线，很贵 —— 所以持有它。
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TaobaoPageWebView(
                    dataStore: store.loginDataStore(),
                    urlString: orderPage,
                    holder: holder
                ) { message in
                    statusText = message
                } onSignedOut: {
                    // 档案里的登录态已经失效 —— 如实标记，别继续显示"已登录"
                    store.markSignedOut()
                }
                // 账号切换后强制重建 WebView —— 每个账号一个独立浏览器档案
                .id(store.activeAccountID ?? "none")
                navigationRow
                statusBar
            }
            .navigationTitle("从网页识别订单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    accountSwitcherMenu
                }
            }
            .sheet(isPresented: $isShowingText) {
                recognizedTextSheet
            }
            .sheet(isPresented: $isShowingReview) {
                reviewSheet
            }
        }
    }

    // MARK: 账号快速切换

    /// 不退出「识别订单」就能换账号 —— 换的是浏览器档案，登录态各自独立。
    private var accountSwitcherMenu: some View {
        Menu {
            ForEach(store.accounts) { account in
                Button {
                    if store.switchTo(accountID: account.id) {
                        statusText = "已切到「\(account.displayName)」，翻到订单页再识别"
                        Haptics.selection()
                    }
                } label: {
                    if account.id == store.activeAccountID {
                        Label(account.displayName, systemImage: "checkmark")
                    } else {
                        Text(account.displayName)
                    }
                }
            }
            Divider()
            Button {
                store.beginAddingAccount()
                statusText = "正在添加新账号：登录完成后会自动切过去"
            } label: {
                Label("添加另一个账号", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: store.isLoggedIn ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle")
                Text(store.activeAccount?.displayName ?? "账号")
            }
            .font(.subheadline.weight(.medium))
        }
    }

    // MARK: 页面导航（进得去，也要出得来）

    private var navigationRow: some View {
        HStack(spacing: 14) {
            Button {
                holder.webView?.goBack()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!holder.canGoBack)
            .accessibilityLabel("后退")

            Button {
                holder.webView?.goForward()
            } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(!holder.canGoForward)
            .accessibilityLabel("前进")

            Button {
                holder.webView?.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel("刷新")

            Text(holder.pageTitle.isEmpty ? "加载中…" : holder.pageTitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
        .font(.footnote)
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: 底部状态栏

    private var statusBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: recognizedText.isEmpty
                      ? "text.viewfinder" : "checkmark.circle.fill")
                    .foregroundStyle(recognizedText.isEmpty ? Color.secondary : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(recognizedText.isEmpty
                         ? "还没有认到字"
                         : "已认到 \(lineCount) 行 · 共 \(recognizedText.count) 字")
                        .font(.subheadline.weight(.medium))
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await recognizeScreen() }
                } label: {
                    HStack(spacing: 6) {
                        if isRecognizing { ProgressView().controlSize(.small) }
                        Label(isRecognizing ? "正在认字…" : "识别这一屏",
                              systemImage: "viewfinder")
                    }
                    .frame(maxWidth: .infinity)
                }
                .artProminentButton()
                .controlSize(.large)
                .disabled(isRecognizing)

                Button {
                    isShowingText = true
                } label: {
                    Label("看 / 改文字", systemImage: "text.alignleft")
                }
                .artGlassButton()
                .controlSize(.large)
                .disabled(recognizedText.isEmpty)
            }

            HStack(spacing: 10) {
                Button {
                    recognizedText = ""
                    lineCount = 0
                    matchedCount = 0
                    droppedCount = 0
                    review = nil
                    selectedItemIDs = []
                    selectedTrackingID = nil
                    statusText = "已清空，可以重新认"
                } label: {
                    Text("清空重来")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(recognizedText.isEmpty)

                Spacer(minLength: 0)

                Button {
                    refreshReview()
                    isShowingReview = true
                } label: {
                    Text("选词条建包裹")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(recognizedText.isEmpty)
            }

            Text("""
            这是淘宝自己的网页（可以点进订单详情、切到「待收货」、用前进后退）。
            App 只做两件事：**把页面上跟你的画材有关的字认出来**，
            以及**把你库里已有的东西当词典去纠正认错的字**。
            不改动页面、不拦截请求、不后台轮询。一屏认不全就翻下一屏再认，文字会累加。
            """)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: 文字（可改）

    private var recognizedTextSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("OCR 难免认错字。这里已经把页面框架（导航、价格、日期、"
                     + "「猜你喜欢」那些）挤掉了 —— 剩下的就是商品和快递单号，"
                     + "可以直接改。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                TextEditor(text: $recognizedText)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(.horizontal, 12)
            }
            .navigationTitle("识别到的文字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("好") {
                        lineCount = recognizedText.split(separator: "\n").count
                        isShowingText = false
                        // 用户可能改过文字，重新解析词条
                        refreshReview()
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("清空", role: .destructive) {
                        recognizedText = ""
                        lineCount = 0
                        review = nil
                        selectedItemIDs = []
                        selectedTrackingID = nil
                    }
                    .disabled(recognizedText.isEmpty)
                }
            }
        }
    }

    // MARK: 词条勾选（单号 + 商品，挑有用的导入）

    /// 从当前识别文字里解析出可勾选的词条。
    ///
    /// 用户在「看 / 改文字」里改完回来、或者重新识别后，这里都要重跑一遍，
    /// 保证勾选页跟文字编辑页看到的是同一份解析结果。
    private func refreshReview() {
        let text = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            review = nil
            selectedItemIDs = []
            selectedTrackingID = nil
            return
        }
        let parsed = OrderTextParser.parse(text)
        let catalog = IncomingPackageService.catalog(in: context)
        let matched = PackageItemMatcher.match(items: parsed.items, against: catalog)

        let entries = zip(parsed.items, matched).map { item, match in
            CaptureReviewItem(
                id: item.id,
                name: item.name,
                quantity: item.quantity,
                rawLine: item.rawLine,
                targetDisplay: match.target.displayName,
                needsConfirmation: match.needsConfirmation
            )
        }
        review = CaptureReview(
            trackingChoices: parsed.trackingCandidates,
            items: entries
        )
        // 默认全选 + 认出的单号，用户按需取消
        selectedItemIDs = Set(entries.map(\.id))
        selectedTrackingID = parsed.trackingNumber ?? parsed.trackingCandidates.first?.number
    }

    /// 把勾选结果拼回文字，回传给外面建包裹。
    private func importSelected() {
        guard let review else { return }
        var lines: [String] = []
        if let tracking = selectedTrackingID {
            lines.append(tracking)
        }
        for entry in review.items where selectedItemIDs.contains(entry.id) {
            lines.append(entry.rawLine)
        }
        onFinish(lines.joined(separator: "\n"))
        dismiss()
    }

    private var reviewSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let review {
                        if !review.trackingChoices.isEmpty {
                            trackingSection(review)
                        }
                        if !review.items.isEmpty {
                            itemsSection(review)
                        } else {
                            Text("这段文字里没认出商品条目。可以点「看 / 改文字」把商品名改清楚，或者直接导入原文。")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Text("还没有识别内容。先翻到订单页点「识别这一屏」。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("选要导入的内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isShowingReview = false }
                }
                // 兜底：一条都没选的时候也能整段带走
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入原文") {
                        onFinish(recognizedText)
                        dismiss()
                    }
                    .disabled(recognizedText.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) { importSelectedBar }
        }
    }

    private func trackingSection(_ review: CaptureReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "快递单号",
                          subtitle: selectedTrackingID.map { "将导入：\($0)" } ?? "不导入单号")
            ForEach(review.trackingChoices) { candidate in
                Button {
                    selectedTrackingID = selectedTrackingID == candidate.number ? nil : candidate.number
                    Haptics.selection()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selectedTrackingID == candidate.number
                              ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selectedTrackingID == candidate.number
                                             ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.number)
                                .font(.system(.body, design: .monospaced))
                            if let carrier = candidate.carrier {
                                Text("\(carrier)（\(candidate.confidence.displayName)）")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(candidate.evidence)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func itemsSection(_ review: CaptureReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "商品词条",
                              subtitle: "已选 \(selectedItemIDs.count) / \(review.items.count) 条")
                Spacer()
                Button(selectedItemIDs.count == review.items.count ? "全不选" : "全选") {
                    selectedItemIDs = selectedItemIDs.count == review.items.count
                        ? []
                        : Set(review.items.map(\.id))
                    Haptics.selection()
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.borderless)
            }
            ForEach(review.items) { entry in
                Button {
                    if selectedItemIDs.contains(entry.id) {
                        selectedItemIDs.remove(entry.id)
                    } else {
                        selectedItemIDs.insert(entry.id)
                    }
                    Haptics.selection()
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: selectedItemIDs.contains(entry.id)
                              ? "checkmark.square.fill" : "square")
                            .foregroundStyle(selectedItemIDs.contains(entry.id)
                                             ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(entry.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(2)
                                Spacer(minLength: 8)
                                Text("×\(entry.quantity)")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 6) {
                                Text(entry.targetDisplay)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if entry.needsConfirmation {
                                    Text("可能不准")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var importSelectedBar: some View {
        let itemCount = selectedItemIDs.count
        let hasTracking = selectedTrackingID != nil
        let label: String
        if itemCount > 0, hasTracking {
            label = "导入 \(itemCount) 条商品 + 快递单号"
        } else if itemCount > 0 {
            label = "导入选中的 \(itemCount) 条商品"
        } else if hasTracking {
            label = "只导入快递单号"
        } else {
            label = "没有选中的内容"
        }
        return VStack(spacing: 0) {
            Button {
                importSelected()
            } label: {
                Label(label, systemImage: "shippingbox")
                    .frame(maxWidth: .infinity)
            }
            .artProminentButton()
            .controlSize(.large)
            .disabled(itemCount == 0 && !hasTracking)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: 截图认字

    /// 用户库里已有的东西 —— 给 OCR 当词典。
    ///
    /// 这是"识别要加强"里最有效的一招：把自己库里的耗材名、颜色名、色号
    /// 交给 Vision 当 `customWords`，这些词的召回与拼写会明显变准；
    /// 认完再用它们把形近字纠回正确写法。
    /// （库里空着时 `catalog` 会退回 42 色预设，所以词典不会是空的。）
    private func knownNames() -> [String] {
        let catalog = IncomingPackageService.catalog(in: context)
        var names = catalog.supplies.map(\.name)
        for color in catalog.colors {
            names.append(color.name)
            names.append(color.code)
            if let ciCode = color.ciCode { names.append(ciCode) }
        }
        return names.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func recognizeScreen() async {
        guard let webView = holder.webView else {
            statusText = "网页还没准备好，稍等一下再点"
            return
        }
        isRecognizing = true
        defer { isRecognizing = false }

        let image: UIImage? = await withCheckedContinuation { continuation in
            let configuration = WKSnapshotConfiguration()
            // ⚠️ 按 2 倍宽度渲染：网页上的商品名比包装上的字小得多，
            //    像素多一点，Vision 认对的概率高不少。
            configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width) * 2)
            webView.takeSnapshot(with: configuration) { snapshot, _ in
                continuation.resume(returning: snapshot)
            }
        }
        guard let image, let cgImage = preparedForOCR(image) else {
            statusText = "截取画面失败，再点一次试试"
            Haptics.alert()
            return
        }

        let vocabulary = knownNames()
        let lines = await ocr.recognize(
            cgImage: cgImage,
            orientation: .up,
            vocabulary: vocabulary,
            // 网页小字：用比默认（0.012）更小的门槛，否则商品名会被整行丢掉
            minimumTextHeight: 0.006
        )
        let cleaned = TaobaoScreenText.clean(lines.map(\.text))
        let rawLines = cleaned.split(separator: "\n").map(String.init)
        // 挤掉页面框架 + 用词典纠错
        let focus = TaobaoScreenFocus.focus(rawLines, knownNames: vocabulary)
        let screen = focus.lines.joined(separator: "\n")

        guard TaobaoScreenText.isUseful(screen) else {
            statusText = rawLines.isEmpty
                ? "这一屏没认到字：等页面加载完，或者把订单卡片放大一点再认"
                : "只认到一点零碎文字，试着让订单内容占满屏幕再认一次"
            Haptics.alert()
            return
        }

        let before = recognizedText
        recognizedText = TaobaoScreenText.append(screen, to: before)
        lineCount = recognizedText.split(separator: "\n").count
        // 累计"认准了几样你的东西"，让用户对识别质量有数
        matchedCount += focus.matchedNames.count
        droppedCount += focus.droppedLines
        if recognizedText == before {
            statusText = "这一屏和上次一样，没有新增内容"
        } else {
            statusText = "认到 \(focus.lines.count) 行，其中 \(focus.matchedNames.count) 行"
                + "对上了你库里的东西；挤掉 \(focus.droppedLines) 行页面文字"
            Haptics.saved()
        }
    }

    /// 认字之前先把截图处理一下：灰度 + 提对比度。
    ///
    /// 淘宝页面是彩色的（橙色价格、灰色标签、彩色商品图），
    /// 灰度化能压掉"颜色干扰"，提对比度让小字更清楚。
    private func preparedForOCR(_ image: UIImage) -> CGImage? {
        guard let ciImage = CIImage(image: image) else { return image.cgImage }
        let adjusted = ciImage.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,
            kCIInputContrastKey: 1.15,
            kCIInputBrightnessKey: 0.0,
        ])
        return Self.ciContext.createCGImage(adjusted, from: adjusted.extent)
            ?? image.cgImage
    }
}

// MARK: - 词条勾选数据

/// 「选词条建包裹」页的一行：从识别文字里解析出的一条商品。
struct CaptureReviewItem: Identifiable {
    /// 与 `ParsedPackageItem.id` 一致（name|quantity|rawLine），用于勾选集合。
    let id: String
    let name: String
    let quantity: Int
    let rawLine: String
    let targetDisplay: String
    let needsConfirmation: Bool
}

/// 「选词条建包裹」页的完整解析结果。
struct CaptureReview {
    var trackingChoices: [TrackingCandidate]
    var items: [CaptureReviewItem]
}

// MARK: - WebView 引用与状态

/// 让 SwiftUI 侧能拿到 WebView（截图 / 前进后退 / 显示标题）。
///
/// `WKWebView` 由 `UIViewRepresentable` 创建，SwiftUI 这边没有引用，
/// 所以用一个共享的小对象在 `makeUIView` 时把它接出来，
/// 顺便把"能不能前进/后退""当前页标题"同步过来驱动按钮状态。
@MainActor
@Observable
final class TaobaoWebViewHolder {
    weak var webView: WKWebView?
    var canGoBack = false
    var canGoForward = false
    var pageTitle = ""

    /// 从当前 WebView 读一次状态（每次导航前后调用）。
    func refresh(from webView: WKWebView?) {
        guard let webView else { return }
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        pageTitle = webView.title ?? webView.url?.host ?? ""
    }
}

// MARK: - 网页

/// 一个**干净的** WKWebView：不做任何注入、不拦任何请求。
///
/// 唯一的"读取"手段是截图认字 —— 之前注入脚本 hook 网络请求，
/// 把页面本身的交互都弄坏了（用户反馈"都操作不了"）。
private struct TaobaoPageWebView: UIViewRepresentable {

    let dataStore: WKWebsiteDataStore
    let urlString: String
    let holder: TaobaoWebViewHolder
    /// 状态文字回传。
    var onStatus: (String) -> Void
    /// 页面被弹回登录页时回调（说明这个账号的登录已失效）。
    var onSignedOut: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 这个账号自己的浏览器档案 —— 登录态天然就在这里，不用注入 cookie
        configuration.websiteDataStore = dataStore
        // ⚠️ 不开这个开关，页面里的 `window.open` 会被直接忽略 ——
        //    淘宝订单卡上的"查看详情"就是这类链接，表现是"点了没反应"。
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        // ⚠️ 用**标准 iPad Safari 的 user agent**。
        //    自己拼一个残缺的串（少了 Version/... Safari/...）会让淘宝
        //    判断成"不认识的浏览器"，可能返回降级页面 —— 链接点不动。
        webView.customUserAgent = "Mozilla/5.0 (iPad; CPU OS 18_7 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 "
            + "Mobile/15E148 Safari/604.1"

        holder.webView = webView
        if let url = URL(string: urlString) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onStatus = onStatus
        context.coordinator.onSignedOut = onSignedOut
        context.coordinator.holder = holder
        holder.webView = webView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(holder: holder, onStatus: onStatus, onSignedOut: onSignedOut)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {

        weak var holder: TaobaoWebViewHolder?
        var onStatus: (String) -> Void
        var onSignedOut: () -> Void

        init(holder: TaobaoWebViewHolder,
             onStatus: @escaping (String) -> Void,
             onSignedOut: @escaping () -> Void) {
            self.holder = holder
            self.onStatus = onStatus
            self.onSignedOut = onSignedOut
        }

        // MARK: 导航状态

        private func syncState(_ webView: WKWebView) {
            Task { @MainActor in
                self.holder?.refresh(from: webView)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in self.holder?.refresh(from: webView) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let url = webView.url
            let title = webView.title
            Task { @MainActor in
                self.holder?.refresh(from: webView)
                // ⚠️ 被弹回登录页 = 这个账号的登录其实已经失效了。
                //    如实标记成"未登录"，不要继续显示"已登录"骗人。
                if !TaobaoLoginDetector.looksLoggedIn(url: url, title: title) {
                    self.onSignedOut()
                    self.onStatus("这个账号需要重新登录（已跳到登录页）")
                    return
                }
                self.onStatus(title.map { "已加载：\($0)" } ?? "页面已加载，翻到订单那一页再点识别")
            }
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            Task { @MainActor in
                self.holder?.refresh(from: webView)
                self.onStatus("页面打不开：\(error.localizedDescription)")
            }
        }

        /// 兜底：有些链接用 `target` 指向不存在的 frame，或者需要新窗口。
        ///
        /// 判据是 `targetFrame == nil` 且这次导航是**用户点链接**触发的 ——
        /// 那种情况我们自己在本 WebView 里加载，否则这一次点击就白点了。
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.targetFrame == nil,
               navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // MARK: 新窗口 / 新标签

        /// `target="_blank"`、`window.open` 都走这里。
        ///
        /// ⚠️ **不实现这个方法，这些链接在 WKWebView 里点了完全没有反应** ——
        ///    淘宝订单卡上的"查看详情/查看物流"正是这种链接。
        ///    处理方式很简单：把请求放回当前 WebView 加载。
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        func webViewDidClose(_ webView: WKWebView) {
            Task { @MainActor in self.holder?.refresh(from: webView) }
        }

        // MARK: JS 弹窗

        // 页面脚本调用 alert/confirm/prompt 时，如果不实现这些代理方法，
        // 弹窗不会出现、**脚本会一直卡在那儿**（后续跳转全部停住）。
        // 这里不弹 UI，只把内容转成状态文字，并把调用放行。

        func webView(_ webView: WKWebView,
                     runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            Task { @MainActor in self.onStatus("页面提示：\(message)") }
            completionHandler()
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            Task { @MainActor in self.onStatus("页面询问：\(message)（已按确定继续）") }
            completionHandler(true)
        }

        func webView(_ webView: WKWebView,
                     runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            // 直接返回用户原来输入的内容（或空），不要卡住页面
            completionHandler(defaultText)
        }
    }
}
