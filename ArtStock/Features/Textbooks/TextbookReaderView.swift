//
//  TextbookReaderView.swift
//  ArtAssist — 美术生的工具箱
//
//  教材阅读器。**这是把原 Python 脚本那份 HTML 阅读器整个换掉的地方。**
//
//  ── 原方案为什么不行（以及这里怎么解决）─────────────────────
//  原方案：生成一份 HTML + 在 a-Shell 里起 http.server + 唤起 Safari。
//
//   1. a-Shell 一进后台就被系统挂起 → 服务器断 → Safari 里翻页失败。
//      现在：没有任何服务器，页面在本 App 里直接渲染。
//   2. 图片全走远程 CDN，没有本地缓存 → 离线不可读、翻页看网速。
//      现在：本地文件优先，缺页才走网络并顺手落盘。
//   3. 视口写了 user-scalable=no，**双指缩放被浏览器禁掉**，
//      但页面底部还写着"支持双指缩放"。
//      现在：真的能双指缩放，双击还能放到 2.5 倍。
//   4. 记不住读到第几页。
//      现在：每翻一页就记进数据库，下次"继续阅读"直接回到那一页。
//   5. Apple Pencil 完全用不上。
//      现在：可以直接在教材上圈画批注（见 PencilCanvasView）。
//
//  ── 交互（照搬原 HTML 那份设计里好的部分）───────────────────
//     点左边 30%   上一页
//     点右边 30%   下一页
//     点中间       呼出/隐藏菜单
//     左右拖动     翻页
//     双指捏合     缩放
//     双击         放大到 2.5 倍 / 还原
//     菜单 2.5 秒无操作自动隐藏
//

import ImageIO
import PencilKit
import SwiftData
import SwiftUI

struct TextbookReaderView: View {

    let textbook: Textbook

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    /// 当前页（1 起）。
    @State private var page: Int = 1
    /// 菜单是否显示。
    @State private var isChromeVisible = true
    /// 菜单自动隐藏的任务。
    ///
    /// ⚠️ 必须持有并取消。原来每调一次就新起一个 Task、旧的不管 ——
    /// 于是"用户点出菜单"和"2.5 秒前那次计时到期"会撞在一起，
    /// 菜单刚出来就被旧的隐藏任务藏掉，表现就是**点了没反应**。
    @State private var chromeHideTask: Task<Void, Never>?
    /// 翻页拖动的位移。
    @State private var dragOffset: CGFloat = 0
    /// 缩放。
    @State private var zoom: CGFloat = 1
    /// 缩放锚点：**永远居中**。
    ///
    /// ⚠️ 这是刻意的，也是用户明确要的（"放大只能中心放大"）。
    ///    跟随捏合点缩放会让页面在手指底下乱窜 —— 看教材时很晕。
    ///    居中放大 + 能拖动（`panOffset`）已经能看任意位置，方向明确得多。
    private let zoomAnchor: UnitPoint = .center
    /// 放大后的拖动位移（只有 zoom > 1 时才动）。
    @State private var panOffset: CGSize = .zero
    /// 本次拖动开始时的位移 —— 拖动是增量的，不记住起点就会跳。
    @State private var panAtDragStart: CGSize = .zero
    /// 各页图片的**原始像素尺寸**，用来算"aspect-fit 之后占多大"（拖动边界）。
    @State private var pageSizes: [Int: CGSize] = [:]
    /// 页面区的容器尺寸（算拖动边界要用，缩放回调里也要用）。
    @State private var pageContainerSize: CGSize = .zero
    /// 见过 Apple Pencil 了（用笔碰过屏）。用来给用户一个明确的反馈。
    @State private var pencilSeen = false
    /// 是否显示页面列表。
    @State private var isShowingPageList = false
    /// 正在输入的页码。
    @State private var pageFieldText = ""
    @State private var isEditingPage = false
    @State private var lastMessage: String?

    // ── Pencil 批注 ──
    @State private var isAnnotating = false
    @State private var tool: AnnotationTool = .thin
    @State private var color: AnnotationColor = .red
    @State private var drawing = PKDrawing()
    @State private var drawingUndoStack: [PKDrawing] = []
    @State private var drawingRedoStack: [PKDrawing] = []
    /// 这本书里有批注的页。
    @State private var annotatedPages: Set<Int> = []
    /// 按需缓存用的下载器。复用一个实例 —— 每页新建一个会连带
    /// 新建一个 URLSession，翻几百页就是几百个会话对象。
    @State private var downloader = TextbookDownloader()

    private var pages: [TextbookPage] { textbook.orderedPages }
    private var pageCount: Int { max(1, pages.count) }

    private var currentPage: TextbookPage? {
        pages.first { $0.pageNumber == page }
    }

    /// 图片的显示内容：本地文件优先，否则远程。
    private enum PageSource {
        case local(URL)
        case remote(String)
        case missing
    }

    private func source(for pageNumber: Int) -> PageSource {
        guard let record = pages.first(where: { $0.pageNumber == pageNumber }) else { return .missing }
        if record.state == .done,
           let url = record.localFileURL(bookName: textbook.name, remoteID: textbook.remoteID),
           FileManager.default.fileExists(atPath: url.path) {
            return .local(url)
        }
        guard !record.remoteURL.isEmpty else { return .missing }
        return .remote(record.remoteURL)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            pageContent

            if isChromeVisible {
                chrome.transition(.opacity)
            }

            // 兜底出口。
            //
            // 阅读器是全屏 + 隐藏系统 UI 的（沉浸阅读该这样），
            // 但那就意味着**菜单一旦唤不出来，用户就被困住了** ——
            // 真实反馈：「点击了一下不知道是防误触了还是啥，没有菜单，返回主页了」，
            // 他是靠回 iPad 主屏才出来的。
            // 所以左上角常驻一个半透明箭头：菜单显示时它是正常的返回按钮，
            // 菜单隐藏时它还在（只是淡一些），任何时候都能退出。
            if !isChromeVisible {
                escapeButton
            }
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(!isChromeVisible)
        .onAppear(perform: onAppear)
        .onDisappear(perform: saveDrawingNow)
        // Apple Pencil 双击笔身 / 捏合笔身。
        // 具体做什么由**用户在系统设置里的绑定**决定 —— 见 PencilPreference。
        // （17.0–17.4 上这个修饰符什么都不做，屏上的批注按钮仍然可用。）
        .pencilShortcuts(
            onDoubleTap: { performPencilIntent(PencilPreference.doubleTapIntent) },
            onSqueeze: { performPencilIntent(PencilPreference.squeezeIntent) }
        )
        .animation(.snappy(duration: 0.22), value: isChromeVisible)
        .animation(.snappy(duration: 0.2), value: page)
        .sheet(isPresented: $isShowingPageList) {
            pageListSheet
        }
        .alert("提示", isPresented: .presentWhen($lastMessage)) {
            Button("好") { lastMessage = nil }
        } message: {
            Text(lastMessage ?? "")
        }
    }

    // MARK: - 页面

    private var pageContent: some View {
        GeometryReader { geometry in
            let size = geometry.size

            ZStack {
                // 相邻页预渲染：翻页时不用等图加载
                if dragOffset != 0 {
                    neighborPreview(offset: dragOffset > 0 ? -1 : 1, size: size)
                }

                pageImage(pageNumber: page, size: size)
                    .scaleEffect(zoom, anchor: zoomAnchor)
                    .offset(x: dragOffset + panOffset.width, y: panOffset.height)

                // 批注层：只有批注模式才接管笔
                if isAnnotating {
                    PencilCanvasView(
                        drawing: $drawing,
                        tool: tool,
                        color: Color(hex: color.hex) ?? .red,
                        isEnabled: true,
                        onChange: handleDrawingChange,
                        onSwipe: { direction in
                            turnPage(direction == .next ? 1 : -1)
                        }
                    )
                    .scaleEffect(zoom, anchor: zoomAnchor)
                    .offset(x: dragOffset + panOffset.width, y: panOffset.height)
                    .allowsHitTesting(true)
                }

                // ── 触摸层：**只留一层** ──────────────────────────
                //
                // 原来这里是三层（tapZones + dragLayer + magnifyLayer）叠着，
                // 上层的单点会让下层的双击手势失败，而 SwiftUI 不会可靠地
                // 把这次单点回传给下层的点击分区 —— 结果中间那一下经常什么都
                // 不发生，菜单唤不出来。
                //
                // 现在单点分区、拖动翻页、捏合缩放全挂在**同一个视图**上，
                // 没有裁决歧义。双击缩放那个手势去掉了（改到菜单里的按钮），
                // 因为"单点分区"和"双击缩放"在同一块区域上必然互相抢。
                if !isAnnotating {
                    touchLayer(size: size)
                }

                // 主动认 Apple Pencil。零尺寸、不吃触摸，只"看"。
                // 挂在页面区里，所以它和翻页/缩放手势在同一棵树上，
                // 又因为收到触摸就立刻失败，不会抢走任何交互。
                PencilTouchObserverView {
                    handlePencilTouch()
                }
                .frame(width: 0, height: 0)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
            .onAppear { pageContainerSize = size }
            .onChange(of: size) { _, newValue in pageContainerSize = newValue }
        }
        .ignoresSafeArea()
        .task(id: page) {
            // 拖动边界要用图片尺寸。只读文件头拿宽高，不解码像素。
            await prefetchPageSizes()
        }
    }

    /// 单页图片。
    @ViewBuilder
    private func pageImage(pageNumber: Int, size: CGSize) -> some View {
        switch source(for: pageNumber) {
        case .local(let url):
            if let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
            } else {
                // 文件坏了/被清了 → 退回远程
                remoteOrMissing(pageNumber: pageNumber, size: size)
            }
        case .remote:
            remoteOrMissing(pageNumber: pageNumber, size: size)
        case .missing:
            missingPageView
        }
    }

    @ViewBuilder
    private func remoteOrMissing(pageNumber: Int, size: CGSize) -> some View {
        if let record = pages.first(where: { $0.pageNumber == pageNumber }),
           !record.remoteURL.isEmpty {
            AsyncImage(url: URL(string: record.remoteURL)) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: size.width, height: size.height)
                case .failure:
                    retryView(pageNumber: pageNumber)
                case .empty:
                    loadingView
                @unknown default:
                    loadingView
                }
            }
            // 这一页显示出来之后顺手缓存到本地 —— 读过一遍就离线可看了
            .task(id: pageNumber) {
                guard let record = pages.first(where: { $0.pageNumber == pageNumber }) else { return }
                await cacheIfNeeded(record)
            }
        } else {
            missingPageView
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("正在加载第 \(page) 页…")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
    }

    private func retryView(pageNumber: Int) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.7))
            Text("第 \(pageNumber) 页加载失败")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
            if let record = pages.first(where: { $0.pageNumber == pageNumber }),
               !record.failureReason.isEmpty {
                Text(record.failureReason)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Button {
                Task { await cacheIfNeeded(pages.first { $0.pageNumber == pageNumber }) }
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
            }
            .artGlassButton()
        }
    }

    private var missingPageView: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.white.opacity(0.7))
            Text("这一页没有内容")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
            Text("第 \(page) 页在服务器上没有对应的图。")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    /// 拖动时把下一页也画出来一点，翻页手感才连贯。
    @ViewBuilder
    private func neighborPreview(offset: Int, size: CGSize) -> some View {
        let neighbor = page + offset
        if neighbor >= 1, neighbor <= pageCount {
            pageImage(pageNumber: neighbor, size: size)
                .offset(x: offset > 0 ? size.width : -size.width)
        }
    }

    // MARK: - 触摸

    /// 唯一的触摸层。
    ///
    /// 挂三件事：单点（按位置分区）、拖动（翻页）、捏合（缩放）。
    /// `.frame` 必须在 `.contentShape` **之前** —— 反过来的话命中区域
    /// 是 frame 之前的尺寸（Color.clear 是零尺寸），点上去没反应。
    private func touchLayer(size: CGSize) -> some View {
        Color.clear
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(dragGesture(size: size))
            .simultaneousGesture(tapGesture(size: size))
            .simultaneousGesture(magnifyGesture)
    }

    /// 单点：按横向位置分区（照搬原 HTML 阅读器的设计，那个设计本身是好的）。
    private func tapGesture(size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 1)
            .onEnded { value in
                // ⚠️ 放大状态下**不再"点一下就还原"**。
                //    原来是那样：放大后随手点一下（想看仔细点）就被弹回原尺寸，
                //    用户想移动视线都做不到，感受就是"放大只能看中间"。
                //    现在放大后单点只切菜单，还原走「还原」按钮或双指捏回去。
                if zoom > 1.01 {
                    toggleChrome()
                    return
                }
                let x = value.location.x
                if x < size.width * 0.3 {
                    turnPage(-1)
                } else if x > size.width * 0.7 {
                    turnPage(1)
                } else {
                    toggleChrome()
                }
            }
    }

    /// 拖动：没放大时翻页，**放大后移动画面**。
    ///
    /// ⚠️ 这里原来在 `zoom > 1` 时直接 `return`，于是放大之后画面完全动不了 ——
    ///    只能看到页面正中间那一块。这正是"放大只能中心放大"的来源。
    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: zoom > 1.01 ? 1 : 16)
            .onChanged { value in
                if zoom > 1.01 {
                    // 放大后：拖动 = 看别处
                    panOffset = ReaderGeometry.clamp(
                        CGSize(width: panAtDragStart.width + value.translation.width,
                               height: panAtDragStart.height + value.translation.height),
                        content: fittedPageSize(in: size),
                        container: size,
                        zoom: zoom
                    )
                    return
                }
                // 只有横向为主时才跟手，纵向拖动不理会
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = value.translation.width
            }
            .onEnded { value in
                guard zoom > 1.01 else {
                    let threshold = size.width * 0.18
                    let predicted = value.predictedEndTranslation.width
                    if value.translation.width < -threshold || predicted < -size.width * 0.4 {
                        turnPage(1)
                    } else if value.translation.width > threshold || predicted > size.width * 0.4 {
                        turnPage(-1)
                    }
                    withAnimation(.snappy(duration: 0.22)) { dragOffset = 0 }
                    return
                }
                // 放大后拖动结束：记下这次的落点，下次拖动从这儿接着算
                panAtDragStart = panOffset
            }
    }

    /// 当前页图片 aspect-fit 之后占多大 —— 拖动边界要按它算。
    ///
    /// 拿不到原始尺寸（远程页还没下载完）时按"占满容器"算：
    /// 那会允许往留白处多拖一点，但绝不会拖不动 —— 宁可多给余量。
    private func fittedPageSize(in container: CGSize) -> CGSize {
        guard let natural = pageSizes[page] else { return container }
        return ReaderGeometry.fitted(content: natural, in: container)
    }

    /// 读图片文件的像素尺寸，**不**解码像素。
    ///
    /// 一页扫描件可能几十兆，为了知道宽高把它整张解进内存不值得 ——
    /// ImageIO 只读文件头就够了。
    private static func pixelSize(ofFileAt url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    /// 预先取当前页与相邻页的图片尺寸（拖动边界要用）。
    private func prefetchPageSizes() async {
        var found: [Int: CGSize] = [:]
        for number in [page - 1, page, page + 1] where number >= 1 && number <= pageCount {
            if pageSizes[number] != nil { continue }
            guard case .local(let url) = source(for: number) else { continue }
            if let size = Self.pixelSize(ofFileAt: url) { found[number] = size }
        }
        guard !found.isEmpty else { return }
        for (number, size) in found { pageSizes[number] = size }
    }

    /// 双指缩放。
    ///
    /// 锚点**永远居中**（见 `zoomAnchor` 的说明）：跟着捏合点缩放会让页面
    /// 在手指底下乱窜，看教材时很晕。居中放大 + 拖动已经能看任意位置。
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom = ReaderGeometry.settledZoom(value.magnification)
                // 边缩边把位移重新夹一遍：缩回去的时候原来拖出去的位移要跟着收回来，
                // 否则会停在"画面偏在一边、还拖不动"的状态。
                panOffset = clampedPan(panOffset)
            }
            .onEnded { _ in
                withAnimation(.snappy(duration: 0.22)) {
                    zoom = ReaderGeometry.settledZoom(zoom)
                    if zoom <= 1.01 {
                        zoom = 1
                        panOffset = .zero
                        panAtDragStart = .zero
                    } else {
                        panOffset = clampedPan(panOffset)
                        panAtDragStart = panOffset
                    }
                }
            }
    }

    /// 把位移夹进当前缩放下的边界（用不到容器尺寸，从页面尺寸表里取）。
    ///
    /// 拿不到尺寸时按"不需要拖动"处理 —— 总比拖到空白处强。
    private func clampedPan(_ offset: CGSize) -> CGSize {
        guard let natural = pageSizes[page] else { return .zero }
        return ReaderGeometry.clamp(
            offset,
            content: ReaderGeometry.fitted(content: natural, in: pageContainerSize),
            container: pageContainerSize,
            zoom: zoom
        )
    }

    /// 兜底返回按钮。菜单隐藏时用低透明度显示，任何时候都点得到。
    private var escapeButton: some View {
        VStack {
            HStack {
                Button {
                    saveDrawingNow()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .artGlassCircle()
                        .opacity(0.45)
                }
                .tint(.white)
                .accessibilityLabel("返回教材列表")

                Spacer()
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 菜单

    private var chrome: some View {
        VStack {
            topBar
            Spacer(minLength: 0)
            if isAnnotating {
                AnnotationToolbar(
                    tool: $tool,
                    color: $color,
                    canUndo: !drawingUndoStack.isEmpty,
                    canRedo: !drawingRedoStack.isEmpty,
                    onUndo: undoDrawing,
                    onRedo: redoDrawing,
                    onClearPage: clearCurrentPageDrawing,
                    onDone: { setAnnotating(false) }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            bottomBar
        }
        .padding(.vertical, 12)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                saveDrawingNow()
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .artGlassCircle()
            }
            .tint(.white)
            .accessibilityLabel("返回")

            VStack(alignment: .leading, spacing: 2) {
                Text(textbook.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitleText)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
            }

            Spacer(minLength: 0)

            if annotatedPages.contains(page) {
                Image(systemName: "pencil.tip.crop.circle")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .accessibilityLabel("这一页有批注")
            }

            // 批注开关
            Button {
                setAnnotating(!isAnnotating)
            } label: {
                Image(systemName: isAnnotating ? "pencil.circle.fill" : "pencil.circle")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .artGlassCircle()
            }
            .tint(isAnnotating ? Theme.accent : .white)
            .accessibilityLabel(isAnnotating ? "退出批注" : "用 Apple Pencil 批注")

            Button {
                isShowingPageList = true
            } label: {
                Image(systemName: "square.grid.2x2")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .artGlassCircle()
            }
            .tint(.white)
            .accessibilityLabel("页面列表")
        }
        .padding(.horizontal, 16)
    }

    private var subtitleText: String {
        var parts = ["第 \(page) / \(pageCount) 页"]
        if zoom > 1.01 {
            // ⚠️ 不能再写"点屏幕任意处还原" —— 放大后单点已经改成切菜单了，
            //    因为随手一点就被弹回原尺寸正是"放大看不仔细"的元凶。
            parts.append("\(Int(zoom * 100))% · 拖动画面 · 双指捏回或按「还原」")
        }
        if pencilSeen, !isAnnotating {
            parts.append("已识别 Apple Pencil")
        }
        if isAnnotating { parts.append("批注中 · 笔用来画，手指用来翻页") }
        return parts.joined(separator: " · ")
    }

    /// 缩放归位。位移必须一起归零，否则会出现"没放大但画面偏着"。
    private func resetZoom() {
        zoom = 1
        panOffset = .zero
        panAtDragStart = .zero
    }

    /// 检测到 Apple Pencil 落笔。
    ///
    /// 这是"主动检测"的落点：手里拿着笔开始写，就不用先去点屏上的批注按钮。
    /// 手指触摸**不会**走到这里（`UITouch.type == .direct`），
    /// 所以翻页、缩放完全不受影响。
    private func handlePencilTouch() {
        if !pencilSeen { pencilSeen = true }
        guard !isAnnotating else { return }
        setAnnotating(true)
        isChromeVisible = true
        scheduleChromeHide()
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            // 进度条：拖动可以快速跳页
            Slider(
                value: Binding(
                    get: { Double(page) },
                    set: { newValue in
                        let target = Int(newValue.rounded())
                        if target != page { go(to: target) }
                    }
                ),
                in: 1...Double(pageCount)
            )
            .tint(Theme.accent)
            .padding(.horizontal, 16)

            HStack(spacing: 18) {
                Button {
                    turnPage(-1)
                } label: {
                    Label("上一页", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .artGlassCircle()
                }
                .disabled(page <= 1)

                HStack(spacing: 6) {
                    TextField("页码", text: $pageFieldText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .frame(width: 62)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(.white)
                        .onSubmit { commitPageField() }
                    Text("/ \(pageCount)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }

                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        if zoom > 1.01 {
                            resetZoom()
                        } else {
                            zoom = 2.5
                            panOffset = .zero
                            panAtDragStart = .zero
                        }
                    }
                } label: {
                    Label(zoom > 1.01 ? "还原" : "放大",
                          systemImage: zoom > 1.01
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .artGlassCircle()
                }

                Button {
                    turnPage(1)
                } label: {
                    Label("下一页", systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .artGlassCircle()
                }
                .disabled(page >= pageCount)
            }
            .tint(.white)
        }
        .padding(.bottom, 6)
    }

    // MARK: - 页面列表

    private var pageListSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 108), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(pages) { record in
                        Button {
                            go(to: record.pageNumber)
                            isShowingPageList = false
                        } label: {
                            pageThumbnail(record)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle("共 \(pageCount) 页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("好") { isShowingPageList = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func pageThumbnail(_ record: TextbookPage) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))

                switch source(for: record.pageNumber) {
                case .local(let url):
                    // ⚠️ 绝不能再用 UIImage(contentsOfFile:) —— 那是把整张
                    // 扫描原图解进内存，预览目录一屏十几格就是上 GB，直接崩。
                    // TextbookThumbnailLoader 只解 720px 缩略图 + 有界缓存。
                    if let image = TextbookThumbnailLoader.thumbnail(at: url) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                case .remote(let urlString):
                    if let url = URL(string: urlString) {
                        RemoteThumbnailView(url: url, placeholderSymbol: record.state.symbolName)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                case .missing:
                    Image(systemName: "doc.questionmark")
                        .foregroundStyle(.secondary)
                }

                // 当前页描边
                if record.pageNumber == page {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: 3)
                }

                // 有批注的标记
                if annotatedPages.contains(record.pageNumber) {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "pencil.tip")
                                .font(.caption2.weight(.bold))
                                .padding(4)
                                .background(.orange, in: Circle())
                                .foregroundStyle(.white)
                        }
                        Spacer()
                    }
                    .padding(6)
                }
            }
            .frame(height: 144)
            .clipped()

            HStack(spacing: 4) {
                Text("\(record.pageNumber)")
                    .font(.caption.weight(record.pageNumber == page ? .bold : .regular))
                    .foregroundStyle(record.pageNumber == page ? Theme.accent : .primary)
                if record.state == .done {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else if record.state == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - 远程缩略图

    /// 远程页缩略图：异步下载 → 降采样 → 缓存。
    ///
    /// ⚠️ 为什么不用 AsyncImage：它会把整张原图下载并**全分辨率解码**，
    ///    预览目录里多格同时渲染时内存直接崩。这里走
    ///    `TextbookThumbnailLoader.remoteThumbnail`，只解 720px 缩略图，
    ///    内存占用与本地缩略图同级。
    ///
    /// `.task(id:)` 挂在格子上：cell 滑出视野时任务自动取消；
    /// 再滑回来时缓存命中，立即出图。
    private struct RemoteThumbnailView: View {
        let url: URL
        let placeholderSymbol: String

        @State private var image: UIImage?

        var body: some View {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: placeholderSymbol)
                        .foregroundStyle(.secondary)
                }
            }
            .task(id: url) {
                let loaded = await TextbookThumbnailLoader.remoteThumbnail(from: url)
                // 任务被取消（cell 已滑出）就别再往回写状态。
                guard !Task.isCancelled else { return }
                image = loaded
            }
        }
    }

    // MARK: - 行为

    private func onAppear() {
        TextbookLibrary.markOpened(textbook, in: context)
        TextbookLibrary.reconcileLocalFiles(of: textbook, in: context)
        page = min(max(1, textbook.resumePage), pageCount)
        pageFieldText = String(page)
        annotatedPages = TextbookStorage.annotatedPages(
            remoteID: textbook.remoteID, name: textbook.name
        )
        loadDrawing(for: page)
        scheduleChromeHide()
    }

    private func toggleChrome() {
        isChromeVisible.toggle()
        if isChromeVisible { scheduleChromeHide() }
    }

    /// 菜单 2.5 秒无操作自动隐藏 —— 原 HTML 阅读器里这个设计很好，照搬。
    ///
    /// ⚠️ 关键在 `chromeHideTask?.cancel()`：不取消的话，上一次的计时会
    /// 在你刚点出菜单之后到期，把菜单立刻又藏掉。
    private func scheduleChromeHide() {
        chromeHideTask?.cancel()
        chromeHideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            // 批注中不自动隐藏：工具条正在被用
            guard !isAnnotating else { return }
            withAnimation(.snappy(duration: 0.25)) { isChromeVisible = false }
        }
    }

    private func turnPage(_ delta: Int) {
        go(to: page + delta)
    }

    private func go(to target: Int) {
        let clamped = max(1, min(pageCount, target))
        guard clamped != page else { return }
        saveDrawingNow()
        page = clamped
        pageFieldText = String(clamped)
        // 翻页要回到 1:1 且居中 —— 新的一页还带着上一页的缩放和位移会很懵
        zoom = 1
        panOffset = .zero
        panAtDragStart = .zero
        dragOffset = 0
        loadDrawing(for: clamped)
        TextbookLibrary.recordReading(clamped, of: textbook, in: context)
        Haptics.selection()
    }

    private func commitPageField() {
        if let target = Int(pageFieldText.trimmingCharacters(in: .whitespaces)) {
            go(to: target)
        }
        pageFieldText = String(page)
    }

    private func cacheIfNeeded(_ record: TextbookPage?) async {
        guard let record, record.state != .done else { return }
        await downloader.cachePage(record, textbook: textbook, context: context)
    }

    // MARK: - 批注

    /// 执行系统设置里绑定的 Pencil 动作。
    ///
    /// 这里的分流逻辑值得说明：用户把双击绑成「切换橡皮」，在**绘画 App** 里
    /// 意思很明确；但在一个阅读器里，没在批注时收到「切换橡皮」是没法执行的。
    /// 所以：已经在批注 → 照做；还没批注 → 先进入批注（这才是用户拿笔点两下
    /// 时想要的结果），然后按需要落在橡皮或笔上。
    private func performPencilIntent(_ intent: PencilIntent) {
        switch intent {
        case .ignore:
            // 用户明确关掉了这个手势 —— 尊重，什么都不做。
            // 屏上的批注按钮仍然是主路径，功能不会因此消失。
            return
        case .toggleAnnotation:
            setAnnotating(!isAnnotating)
            if isAnnotating { lastMessage = nil }
        case .eraser:
            if !isAnnotating { setAnnotating(true) }
            tool = .eraser
            Haptics.selection()
        case .pen:
            if !isAnnotating { setAnnotating(true) }
            tool = .thin
            Haptics.selection()
        }
    }

    private func setAnnotating(_ on: Bool) {
        isAnnotating = on
        if on {
            isChromeVisible = true
            loadDrawing(for: page)
        } else {
            saveDrawingNow()
            scheduleChromeHide()
        }
        Haptics.selection()
    }

    private func loadDrawing(for pageNumber: Int) {
        guard let data = TextbookStorage.loadDrawing(
            remoteID: textbook.remoteID, name: textbook.name, page: pageNumber
        ), let restored = try? PKDrawing(data: data) else {
            drawing = PKDrawing()
            drawingUndoStack.removeAll()
            drawingRedoStack.removeAll()
            return
        }
        drawing = restored
        drawingUndoStack.removeAll()
        drawingRedoStack.removeAll()
    }

    private func handleDrawingChange(_ newDrawing: PKDrawing) {
        // 撤销栈只留最近 30 步 —— 一本教材翻几百页，不设上限会吃光内存
        if let last = drawingUndoStack.last,
           last.dataRepresentation() == newDrawing.dataRepresentation() {
            return
        }
        drawingUndoStack.append(drawing)
        if drawingUndoStack.count > 30 { drawingUndoStack.removeFirst() }
        drawingRedoStack.removeAll()
        drawing = newDrawing
        saveDrawingNow()
    }

    private func undoDrawing() {
        guard let previous = drawingUndoStack.popLast() else { return }
        drawingRedoStack.append(drawing)
        drawing = previous
        saveDrawingNow()
        Haptics.selection()
    }

    private func redoDrawing() {
        guard let next = drawingRedoStack.popLast() else { return }
        drawingUndoStack.append(drawing)
        drawing = next
        saveDrawingNow()
        Haptics.selection()
    }

    private func clearCurrentPageDrawing() {
        guard !drawing.strokes.isEmpty else { return }
        drawingUndoStack.append(drawing)
        drawingRedoStack.removeAll()
        drawing = PKDrawing()
        saveDrawingNow()
        lastMessage = "已清除第 \(page) 页的批注。"
    }

    /// 把当前页的批注写到磁盘。
    private func saveDrawingNow() {
        guard isAnnotating || !drawing.strokes.isEmpty else { return }
        let data = drawing.strokes.isEmpty ? nil : drawing.dataRepresentation()
        TextbookStorage.saveDrawing(
            data, remoteID: textbook.remoteID, name: textbook.name, page: page
        )
        // 更新"这页有批注"的集合
        if drawing.strokes.isEmpty {
            annotatedPages.remove(page)
        } else {
            annotatedPages.insert(page)
        }
    }
}
