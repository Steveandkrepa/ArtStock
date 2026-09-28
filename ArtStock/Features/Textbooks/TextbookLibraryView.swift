//
//  TextbookLibraryView.swift
//  ArtAssist — 美术生的工具箱
//
//  教材库：我的教材 + 搜索。
//
//  ── 对应原 Python 脚本的哪一段 ───────────────────────────────
//      search_books(keyword)   → 这一页的搜索
//      questionary.select(...) → 搜索结果列表（原来是在终端里选序号）
//      下载/阅读二选一          → 详情页里的两个按钮
//
//  原脚本每运行一次都要重新登录、重新搜索、重新取页。
//  这里"我的教材"是存下来的，打开 App 直接继续读。
//

import SwiftData
import SwiftUI

struct TextbookLibraryView: View {

    @Environment(\.modelContext) private var context

    @Query(sort: [SortDescriptor(\Textbook.addedAt, order: .reverse)])
    private var books: [Textbook]

    @State private var session = DXArtSession.shared
    @State private var downloader = TextbookDownloader()

    @State private var tab: Tab = .mine
    @State private var keyword = ""
    @State private var results: [TextbookSummary] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var hasSearched = false
    @State private var isShowingLogin = false
    @State private var openedBook: Textbook?
    @State private var isShowingDownloadManager = false
    @State private var pendingDeleteBook: Textbook?

    enum Tab: String, CaseIterable, Identifiable {
        case mine
        case search

        var id: String { rawValue }
        var title: String {
            switch self {
            case .mine: return "我的教材"
            case .search: return "找教材"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !session.isLoggedIn {
                    loginPrompt
                }

                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                switch tab {
                case .mine:
                    mineSection
                case .search:
                    searchSection
                }
            }
            .padding(20)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .artScrollEdgeEffect()
        .navigationTitle("教材")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingDownloadManager = true
                } label: {
                    Label("下载管理", systemImage: "internaldrive")
                }
            }
        }
        .sheet(isPresented: $isShowingDownloadManager) {
            TextbookDownloadManagerView()
        }
        .confirmationDialog(
            "删除《\(pendingDeleteBook?.name ?? "")》？",
            isPresented: .presentWhen($pendingDeleteBook),
            titleVisibility: .visible
        ) {
            Button("删除整本（含批注）", role: .destructive) {
                if let book = pendingDeleteBook {
                    TextbookLibrary.remove(book, in: context)
                    Haptics.alert()
                }
                pendingDeleteBook = nil
            }
            if let book = pendingDeleteBook, book.downloadStats.done > 0 {
                Button("只删本地页图（保留批注）") {
                    TextbookLibrary.removeLocalFiles(of: book, in: context)
                    Haptics.saved()
                    pendingDeleteBook = nil
                }
            }
            Button("取消", role: .cancel) { pendingDeleteBook = nil }
        } message: {
            Text("删整本会连 Apple Pencil 批注一起删。平台上不受影响，还能重新加回来。")
        }
        .sheet(isPresented: $isShowingLogin) {
            DXArtLoginView(session: session) { tab = .search }
        }
        .sheet(item: $openedBook) { book in
            TextbookDetailView(book: book, session: session, downloader: downloader)
        }
        .onAppear {
            if !session.isLoggedIn, !session.savedPhone.isEmpty {
                // 有记住的手机号就直接弹出登录，省一次点击
                isShowingLogin = true
            }
        }
    }

    // MARK: - 未登录

    private var loginPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("还没登录教材平台", systemImage: "person.badge.key")
                .font(.headline)
            Text("搜索和下载教材需要你账号的凭证。颜料盒、保湿计时这些功能不受影响。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                isShowingLogin = true
            } label: {
                Label("去登录", systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .artProminentButton()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - 我的教材

    @ViewBuilder
    private var mineSection: some View {
        if books.isEmpty {
            EmptyState(
                title: "还没有教材",
                message: "切到「找教材」搜一本加进来。加进来之后就可以下载到本地、离线阅读、"
                       + "用 Apple Pencil 在上面批注。",
                symbolName: "books.vertical",
                actionTitle: "去找教材"
            ) {
                tab = .search
            }
            .frame(minHeight: 240)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                    Button {
                        TextbookLibrary.markOpened(book, in: context)
                        openedBook = book
                    } label: {
                        bookRow(book)
                    }
                    .buttonStyle(.plain)
                    // 长按就能删，不用点进详情页再滚到底 ——
                    // 真实反馈：「不能删除不够方便」。
                    .contextMenu {
                        Button {
                            TextbookLibrary.markOpened(book, in: context)
                            openedBook = book
                        } label: {
                            Label("打开", systemImage: "book")
                        }

                        if book.downloadStats.done > 0 {
                            Button {
                                TextbookLibrary.removeLocalFiles(of: book, in: context)
                                Haptics.saved()
                            } label: {
                                Label("删除本地页图（保留批注）", systemImage: "trash")
                            }
                        }

                        if book.lastReadPage > 0 {
                            Button {
                                book.lastReadPage = 0
                                try? context.save()
                                Haptics.selection()
                            } label: {
                                Label("标记为未读", systemImage: "arrow.counterclockwise")
                            }
                        }

                        Divider()

                        Button(role: .destructive) {
                            pendingDeleteBook = book
                        } label: {
                            Label("删除整本教材", systemImage: "trash.slash")
                        }
                    }

                    if index < books.count - 1 {
                        Divider().padding(.leading, 76)
                    }
                }
            }
            .cardStyle(padding: 8)
        }
    }

    private func bookRow(_ book: Textbook) -> some View {
        HStack(spacing: 14) {
            coverThumbnail(book, size: 56, corner: 10)

            VStack(alignment: .leading, spacing: 3) {
                Text(book.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(book.readingProgressText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    if book.isFullyDownloaded {
                        Label("已离线", systemImage: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else if book.downloadStats.done > 0 {
                        Text("已下 \(book.downloadStats.summary)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    let annotated = TextbookStorage.annotatedPages(
                        remoteID: book.remoteID, name: book.name
                    ).count
                    if annotated > 0 {
                        Label("\(annotated) 页有批注", systemImage: "pencil.tip")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Spacer(minLength: 0)

            if book.lastReadPage > 0 {
                Text("\(Int(book.readingFraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func coverThumbnail(_ book: Textbook, size: CGFloat, corner: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))

            // 本地封面优先（离线也能看）
            if let directory = TextbookStorage.bookDirectory(remoteID: book.remoteID, name: book.name) {
                let coverPath = directory.appendingPathComponent(TextbookStorage.coverFileName)
                if let image = UIImage(contentsOfFile: coverPath.path) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if !book.coverURL.isEmpty {
                    AsyncImage(url: URL(string: book.coverURL)) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "book.closed")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Image(systemName: "book.closed")
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "book.closed")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size * 1.34)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    // MARK: - 搜索

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                TextField("书名关键字，如「色彩静物」", text: $keyword)
                    .textFieldStyle(.plain)
                    .submitLabel(.search)
                    .onSubmit { Task { await runSearch() } }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Button {
                    Task { await runSearch() }
                } label: {
                    if isSearching {
                        ProgressView()
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .artGlassButton()
                .disabled(isSearching || keyword.trimmed.isEmpty || !session.isLoggedIn)
            }
            .cardStyle()

            if let searchError {
                NoticeBanner(level: .error, title: "搜索失败", message: searchError)
            }

            if !results.isEmpty {
                Text("找到 \(results.count) 本")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, summary in
                        searchRow(summary)
                        if index < results.count - 1 {
                            Divider().padding(.leading, 76)
                        }
                    }
                }
                .cardStyle(padding: 8)
            } else if hasSearched, !isSearching, searchError == nil {
                EmptyState(
                    title: "没找到这本书",
                    message: "换一个关键字试试。平台上的教材名字通常比较长，"
                           + "搜「色彩」「速写」「素描」这类词命中率更高。",
                    symbolName: "magnifyingglass"
                )
                .frame(minHeight: 200)
            } else if !session.isLoggedIn {
                EmptyState(
                    title: "先登录才能搜索",
                    message: "教材接口需要你账号的凭证。",
                    symbolName: "person.badge.key",
                    actionTitle: "去登录"
                ) {
                    isShowingLogin = true
                }
                .frame(minHeight: 200)
            }
        }
    }

    private func searchRow(_ summary: TextbookSummary) -> some View {
        let alreadyAdded = books.contains { $0.remoteID == summary.remoteID }

        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
                if let cover = summary.coverURL, !cover.isEmpty {
                    AsyncImage(url: URL(string: cover)) { phase in
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
            .frame(width: 56, height: 74)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(summary.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Label("\(summary.viewCount) 次浏览", systemImage: "eye")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if alreadyAdded {
                Label("已加入", systemImage: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(.green)
            } else {
                Button {
                    let added = TextbookLibrary.add(summary, in: context)
                    Haptics.saved()
                    TextbookLibrary.markOpened(added, in: context)
                    openedBook = added
                } label: {
                    Text("加入")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
    }

    // MARK: - 搜索动作

    private func runSearch() async {
        let text = keyword.trimmed
        guard !text.isEmpty else { return }
        isSearching = true
        searchError = nil
        hasSearched = true
        defer { isSearching = false }

        do {
            results = try await session.search(keyword: text)
            // 凭证失效时 session 会自动登出，这里提示一下
            if !session.isLoggedIn {
                searchError = "登录已失效，请重新登录。"
            }
        } catch {
            results = []
            searchError = error.localizedDescription
        }
    }
}
