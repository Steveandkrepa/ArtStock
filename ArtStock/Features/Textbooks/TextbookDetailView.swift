//
//  TextbookDetailView.swift
//  ArtAssist — 美术生的工具箱
//
//  一本教材的详情 + 下载中心。
//
//  ── 这里是原 Python 脚本"下载模式"的正经版本 ────────────────
//  原脚本给两个选项：① 生成阅读器（免下载）② 8 线程下全部原图。
//  在 App 里这两件事不该是二选一 —— 应该是：
//
//    · 直接就能读（在线加载，读过的页自动留在本地）
//    · 想离线就点「下载整本」，有进度、能暂停、能只重试失败的那几页
//
//  页状态网格让用户**看得见**每一页的状态。原脚本只有刷屏日志，
//  跑完就没了，哪几页失败根本无从查起。
//

import SwiftData
import SwiftUI

struct TextbookDetailView: View {

    let book: Textbook
    let session: DXArtSession
    let downloader: TextbookDownloader

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var isReading = false
    @State private var isSyncing = false
    @State private var syncError: String?
    @State private var message: String?
    @State private var isConfirmingDelete = false
    @State private var isConfirmingClearLocal = false
    @State private var annotatedPages: Set<Int> = []
    @State private var localBytes: Int64 = 0
    /// 页网格的多选模式。
    @State private var isSelectingPages = false
    @State private var selectedPages: Set<Int> = []

    private var pages: [TextbookPage] { book.orderedPages }
    private var stats: DownloadStats { book.downloadStats }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerCard
                    readingCard
                    downloadCard
                    if !pages.isEmpty { pageGridCard }
                    annotationCard
                    dangerCard
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .artScrollEdgeEffect()
            .navigationTitle("教材详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $isReading) {
                TextbookReaderView(textbook: book)
            }
            .alert("提示", isPresented: .presentWhen($message)) {
                Button("好") { message = nil }
            } message: {
                Text(message ?? "")
            }
            .confirmationDialog("删除这本教材？", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("删除（含本地文件和批注）", role: .destructive) {
                    TextbookLibrary.remove(book, in: context)
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("本地下载的页和 Apple Pencil 批注会一起删掉，平台上不受影响。")
            }
            .confirmationDialog("删除本地文件？", isPresented: $isConfirmingClearLocal, titleVisibility: .visible) {
                Button("删除下载的页", role: .destructive) {
                    TextbookLibrary.removeLocalFiles(of: book, in: context)
                    refreshLocalState()
                    message = "已删除本地页图，批注保留。下次在线阅读时会重新缓存。"
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("批注不会删。阅读进度也会保留。")
            }
            .onAppear(perform: refreshLocalState)
            .task { await ensurePages() }
        }
    }

    // MARK: - 头部

    private var headerCard: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                if let url = coverFileURL, let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                } else if !book.coverURL.isEmpty {
                    AsyncImage(url: URL(string: book.coverURL)) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "book.closed").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Image(systemName: "book.closed").foregroundStyle(.secondary)
                }
            }
            .frame(width: 100, height: 134)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(book.name)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                Label("\(book.viewCount) 次浏览", systemImage: "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(book.readingProgressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if book.pageCount > 0 {
                    ProgressView(value: book.readingFraction)
                        .tint(Theme.accent)
                        .frame(maxWidth: 200)
                }
            }

            Spacer(minLength: 0)
        }
        .cardStyle()
    }

    private var coverFileURL: URL? {
        TextbookStorage.bookDirectory(remoteID: book.remoteID, name: book.name)?
            .appendingPathComponent(TextbookStorage.coverFileName)
    }

    // MARK: - 阅读

    private var readingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "阅读",
                subtitle: pages.isEmpty ? "还没取到页列表" : "共 \(pages.count) 页"
            )

            if pages.isEmpty {
                if isSyncing {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在取页列表…").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        Task { await ensurePages(force: true) }
                    } label: {
                        Label("重新取页列表", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .artProminentButton()
                }

                if let syncError {
                    NoticeBanner(level: .error, title: "取页失败", message: syncError)
                }
            } else {
                HStack(spacing: 12) {
                    Button {
                        TextbookLibrary.markOpened(book, in: context)
                        isReading = true
                    } label: {
                        Label(book.lastReadPage > 0 ? "继续阅读（第 \(book.resumePage) 页）" : "开始阅读",
                              systemImage: "book.pages")
                            .frame(maxWidth: .infinity)
                    }
                    .artProminentButton()
                    .controlSize(.large)

                    Button {
                        isReading = true
                    } label: {
                        Label("目录", systemImage: "square.grid.2x2")
                    }
                    .artGlassButton()
                    .controlSize(.large)
                    .disabled(pages.isEmpty)
                }

                Text("Apple Pencil 用来圈画批注，手指用来翻页与缩放。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - 下载

    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "离线下载", subtitle: stats.summary)

            if !pages.isEmpty {
                ProgressView(value: stats.fraction)
                    .tint(stats.failed > 0 ? .orange : Theme.accent)

                if downloader.isRunning, !downloader.etaText.isEmpty {
                    Text("预计还要 \(downloader.etaText) · 已下 \(TextbookFormat.bytes(downloader.transferredBytes))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    if downloader.isRunning {
                        Button {
                            downloader.stop(context: context)
                        } label: {
                            Label("暂停", systemImage: "pause.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .artGlassButton()
                        .controlSize(.large)
                    } else {
                        Button {
                            downloader.start(textbook: book, context: context)
                        } label: {
                            Label(stats.done > 0 ? "继续下载" : "下载整本",
                                  systemImage: "arrow.down.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .artProminentButton()
                        .controlSize(.large)
                        .disabled(!stats.canStart)
                    }

                    if stats.failed > 0, !downloader.isRunning {
                        Button {
                            downloader.start(textbook: book, context: context, onlyFailed: true)
                        } label: {
                            Label("重试失败的 \(stats.failed) 页", systemImage: "arrow.clockwise")
                        }
                        .artGlassButton()
                        .controlSize(.large)
                    }
                }

                HStack(spacing: 16) {
                    Label("本地 \(TextbookFormat.bytes(localBytes))", systemImage: "internaldrive")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if stats.isComplete {
                        Label("已可离线阅读", systemImage: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            } else {
                Text("先取到页列表才能下载。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("同时下 \(TextbookDownloader.maxConcurrent) 页，失败自动重试。"
                 + "中途退出也不丢进度，回来点「继续下载」即可。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - 页状态

    private var pageGridCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(
                    title: "每页状态",
                    subtitle: isSelectingPages
                        ? "点格子选中，或长按也行"
                        : "点一页重下 · 长按可删本地文件"
                )
                Spacer(minLength: 8)
                Button(isSelectingPages ? "完成" : "选择") {
                    withAnimation(.snappy(duration: 0.2)) {
                        isSelectingPages.toggle()
                        if !isSelectingPages { selectedPages.removeAll() }
                    }
                    Haptics.selection()
                }
                .font(.subheadline)
                .buttonStyle(.borderless)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 54), spacing: 6)],
                spacing: 6
            ) {
                ForEach(pages) { page in
                    Button {
                        if isSelectingPages {
                            toggleSelection(page.pageNumber)
                        } else {
                            redownload(page)
                        }
                    } label: {
                        pageCell(page)
                    }
                    .buttonStyle(.plain)
                    .disabled(page.state == .downloading && !isSelectingPages)
                    .contextMenu {
                        Button {
                            selectedPages = [page.pageNumber]
                            isSelectingPages = true
                        } label: {
                            Label("选中这一页", systemImage: "checkmark.circle")
                        }

                        if page.state == .done {
                            Button(role: .destructive) {
                                deleteLocal(page)
                            } label: {
                                Label("删除这一页的本地文件", systemImage: "trash")
                            }
                        }

                        Button {
                            redownload(page)
                        } label: {
                            Label("重新下载这一页", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }

            if isSelectingPages {
                selectionBar
            } else {
                HStack(spacing: 14) {
                    legendItem("已完成", color: .green)
                    legendItem("失败", color: .orange)
                    legendItem("待下载", color: Color(uiColor: .tertiarySystemFill))
                    legendItem("有批注", color: .orange, isDot: true)
                }
                .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// 单个页格子。
    private func pageCell(_ page: TextbookPage) -> some View {
        let isSelected = selectedPages.contains(page.pageNumber)
        return ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(backgroundColor(for: page))

            if isSelectingPages {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : Color.clear, lineWidth: 2.5)
            }

            // 有批注的页打一个橙点
            if annotatedPages.contains(page.pageNumber), !isSelectingPages {
                VStack {
                    HStack {
                        Spacer()
                        Circle().fill(.orange).frame(width: 5, height: 5)
                    }
                    Spacer()
                }
                .padding(4)
            }

            if isSelectingPages, isSelected {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.accent)
            } else {
                Text("\(page.pageNumber)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(foregroundColor(for: page))
            }
        }
        .frame(height: 34)
    }

    /// 多选模式下底部那一条：删 / 重下 / 全选。
    private var selectionBar: some View {
        VStack(spacing: 10) {
            Divider()

            HStack(spacing: 12) {
                Text(selectedPages.isEmpty ? "还没选" : "已选 \(selectedPages.count) 页")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Button(selectedPages.count == pages.count ? "取消全选" : "全选") {
                    if selectedPages.count == pages.count {
                        selectedPages.removeAll()
                    } else {
                        selectedPages = Set(pages.map(\.pageNumber))
                    }
                    Haptics.selection()
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    deleteSelectedLocal()
                } label: {
                    Label("删除本地文件", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .artGlassButton()
                .controlSize(.large)
                .disabled(selectedPages.isEmpty)

                Button {
                    redownloadSelected()
                } label: {
                    Label("重新下载", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .artGlassButton()
                .controlSize(.large)
                .disabled(selectedPages.isEmpty)
            }

            Text("删除的是本地页图，批注与阅读进度保留。以后重新打开会自动按需缓存。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func backgroundColor(for page: TextbookPage) -> Color {
        switch page.state {
        case .done: return .green.opacity(0.22)
        case .failed: return .orange.opacity(0.25)
        case .downloading: return Theme.accent.opacity(0.3)
        case .pending: return Color(uiColor: .tertiarySystemFill)
        }
    }

    private func foregroundColor(for page: TextbookPage) -> Color {
        switch page.state {
        case .done: return .green
        case .failed: return .orange
        case .downloading: return Theme.accent
        case .pending: return .secondary
        }
    }

    private func legendItem(_ text: String, color: Color, isDot: Bool = false) -> some View {
        HStack(spacing: 4) {
            if isDot {
                Circle().fill(color).frame(width: 6, height: 6)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.5)).frame(width: 10, height: 10)
            }
            Text(text)
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - 批注

    private var annotationCard: some View {
        let count = annotatedPages.count
        let bytes = TextbookStorage.drawingByteCount(remoteID: book.remoteID, name: book.name)

        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Apple Pencil 批注", subtitle: count > 0 ? "\(count) 页有批注" : "还没有批注")

            if count > 0 {
                Text("占用 \(TextbookFormat.bytes(bytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(role: .destructive) {
                    TextbookStorage.removeAllDrawings(remoteID: book.remoteID, name: book.name)
                    refreshLocalState()
                    message = "已清除这本教材的全部批注。"
                } label: {
                    Label("清除全部批注", systemImage: "eraser")
                        .frame(maxWidth: .infinity)
                }
                .artGlassButton()
            } else {
                Text("阅读时点右上角的铅笔图标进入批注，用 Apple Pencil 圈重点、画结构线。"
                     + "笔迹按页保存，下次打开还在。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - 危险操作

    private var dangerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if stats.done > 0 {
                Button {
                    isConfirmingClearLocal = true
                } label: {
                    Label("删除本地下载的页（保留批注）", systemImage: "trash.slash")
                        .frame(maxWidth: .infinity)
                }
                .artGlassButton()
            }

            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("从我的教材里删除", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .artGlassButton()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - 行为

    private func refreshLocalState() {
        annotatedPages = TextbookStorage.annotatedPages(remoteID: book.remoteID, name: book.name)
        localBytes = book.localBytes
    }

    /// 取页列表（第一次打开时自动做一次）。
    private func ensurePages(force: Bool = false) async {
        guard !isSyncing else { return }
        if !force, !pages.isEmpty { return }
        guard session.isLoggedIn else {
            syncError = "需要先登录教材平台。"
            return
        }

        isSyncing = true
        syncError = nil
        defer { isSyncing = false }

        do {
            let infos = try await session.chapters(textbookID: book.remoteID)
            let result = TextbookLibrary.syncPages(infos, into: book, in: context)
            // 顺手把封面存到本地，离线也能看到
            await cacheCoverIfNeeded()
            refreshLocalState()
            if force {
                message = "页列表已更新：新增 \(result.added) 页，移除 \(result.removed) 页。"
            }
        } catch {
            syncError = error.localizedDescription
        }
    }

    private func cacheCoverIfNeeded() async {
        guard !book.coverURL.isEmpty else { return }
        guard let url = TextbookStorage.coverURL(remoteID: book.remoteID, name: book.name) else { return }
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = try? await session.imageData(from: book.coverURL) else { return }
        TextbookStorage.ensureDirectory(url.deletingLastPathComponent())
        try? data.write(to: url, options: .atomic)
    }

    private func toggleSelection(_ pageNumber: Int) {
        if selectedPages.contains(pageNumber) {
            selectedPages.remove(pageNumber)
        } else {
            selectedPages.insert(pageNumber)
        }
        Haptics.selection()
    }

    /// 删掉选中的页的本地文件。
    private func deleteSelectedLocal() {
        let targets = pages.filter { selectedPages.contains($0.pageNumber) }
        guard !targets.isEmpty else { return }
        let removed = TextbookLibrary.removeLocalFiles(of: book, pages: targets, in: context)
        selectedPages.removeAll()
        isSelectingPages = false
        refreshLocalState()
        Haptics.saved()
        message = removed > 0
            ? "已删除 \(targets.count) 页的本地文件（实际删了 \(removed) 个）。批注和进度都还在。"
            : "这 \(targets.count) 页本来就没有本地文件。"
    }

    /// 重新下载选中的页。
    private func redownloadSelected() {
        let count = selectedPages.count
        guard count > 0 else { return }
        for page in pages where selectedPages.contains(page.pageNumber) {
            if let url = page.localFileURL(bookName: book.name, remoteID: book.remoteID) {
                try? FileManager.default.removeItem(at: url)
            }
            page.state = .pending
            page.localRelativePath = ""
            page.byteCount = 0
            page.failureReason = ""
        }
        try? context.save()
        selectedPages.removeAll()
        isSelectingPages = false
        downloader.start(textbook: book, context: context)
        Haptics.selection()
    }

    /// 删单页的本地文件（长按菜单用）。
    private func deleteLocal(_ page: TextbookPage) {
        let removed = TextbookLibrary.removeLocalFiles(of: book, pages: [page], in: context)
        refreshLocalState()
        Haptics.saved()
        message = removed > 0
            ? "已删除第 \(page.pageNumber) 页的本地文件。"
            : "第 \(page.pageNumber) 页本来就没有本地文件。"
    }

    private func redownload(_ page: TextbookPage) {
        guard page.state == .done else {
            // 没下好的页：把这一页塞回去单独下一次
            page.state = .pending
            page.failureReason = ""
            try? context.save()
            downloader.start(textbook: book, context: context)
            return
        }
        // 已下好的页：删掉本地文件重新下
        if let url = page.localFileURL(bookName: book.name, remoteID: book.remoteID) {
            try? FileManager.default.removeItem(at: url)
        }
        page.state = .pending
        page.localRelativePath = ""
        page.byteCount = 0
        try? context.save()
        downloader.start(textbook: book, context: context)
        Haptics.selection()
    }
}
