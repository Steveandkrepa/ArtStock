//
//  TextbookDownloadManagerView.swift
//  ArtAssist — 美术生的工具箱
//
//  下载管理：一眼看清本地占了多少，随时能删。
//
//  ── 为什么要单独做一个 ───────────────────────────────────────
//  真实反馈：「下载管理不够好，不能删除不够方便」。
//
//  原来删除入口埋在**每本书详情页的最底部**（"危险操作"那个卡片），
//  要删本地文件得：教材库 → 点进那本书 → 滚到最底 → 点删除。
//  想看"一共占了多少"更是没地方看。
//
//  这里把三件事集中起来：
//    · 总占用（页图 + 批注分开算）
//    · 每本书的占用与两个删除动作（删本地页 / 删整本）
//    · 一键清空全部本地教材
//
//  删除的语义要说清楚，否则用户不敢点：
//    · 删本地页图 → 批注、阅读进度都保留；下次打开会自动按需缓存
//    · 删整本     → 连批注一起删；平台上不受影响，还能重新加回来
//

import SwiftData
import SwiftUI

struct TextbookDownloadManagerView: View {

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: [SortDescriptor(\Textbook.addedAt, order: .reverse)])
    private var books: [Textbook]

    @State private var message: String?
    @State private var pendingDelete: Textbook?
    @State private var isConfirmingClearAll = false
    /// 本地占用快照。删完要重算，所以不直接在 body 里算。
    @State private var bytesByBook: [Int: Int64] = [:]
    @State private var drawingBytesByBook: [Int: Int64] = [:]
    @State private var isMeasuring = false

    private var totalPageBytes: Int64 {
        bytesByBook.values.reduce(0, +)
    }

    private var totalDrawingBytes: Int64 {
        drawingBytesByBook.values.reduce(0, +)
    }

    private var booksWithLocalFiles: [Textbook] {
        books.filter { (bytesByBook[$0.remoteID] ?? 0) > 0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    storageCard

                    if booksWithLocalFiles.isEmpty {
                        EmptyState(
                            title: "本地没有下载的教材",
                            message: "在教材详情页点「下载整本」可以离线阅读。"
                                 + "在线阅读过的页也会自动缓存到本地。",
                            symbolName: "internaldrive"
                        )
                        .frame(minHeight: 200)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(booksWithLocalFiles.enumerated()), id: \.element.id) { index, book in
                                bookRow(book)
                                if index < booksWithLocalFiles.count - 1 {
                                    Divider().padding(.leading, 16)
                                }
                            }
                        }
                        .cardStyle(padding: 8)

                        Button(role: .destructive) {
                            isConfirmingClearAll = true
                        } label: {
                            Label("清空全部本地教材（保留批注）", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .artGlassButton()
                        .controlSize(.large)
                    }
                }
                .padding(20)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .artScrollEdgeEffect()
            .navigationTitle("下载管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("提示", isPresented: .presentWhen($message)) {
                Button("好") { message = nil }
            } message: {
                Text(message ?? "")
            }
            .confirmationDialog(
                "删除《\(pendingDelete?.name ?? "")》的整本教材？",
                isPresented: .presentWhen($pendingDelete),
                titleVisibility: .visible
            ) {
                Button("删除（含批注）", role: .destructive) {
                    if let book = pendingDelete {
                        TextbookLibrary.remove(book, in: context)
                        refreshSizes()
                        message = "已删除《\(book.name)》，本地文件和批注一起清掉了。平台上不受影响。"
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            }
            .confirmationDialog("清空全部本地教材？", isPresented: $isConfirmingClearAll, titleVisibility: .visible) {
                Button("清空本地页图（保留批注）", role: .destructive) {
                    var count = 0
                    for book in books where (bytesByBook[book.remoteID] ?? 0) > 0 {
                        TextbookLibrary.removeLocalFiles(of: book, in: context)
                        count += 1
                    }
                    refreshSizes()
                    Haptics.alert()
                    message = "已清空 \(count) 本教材的本地页图。批注全部保留。"
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("页图会删掉，Apple Pencil 批注和阅读进度保留。以后打开会自动按需缓存。")
            }
            .onAppear(perform: refreshSizes)
        }
    }

    // MARK: - 总占用

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "internaldrive")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)

                VStack(alignment: .leading, spacing: 4) {
                    Text(TextbookFormat.bytes(totalPageBytes + totalDrawingBytes))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text("教材在本地一共占了这么多")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if isMeasuring {
                    ProgressView()
                }
            }

            Divider()

            HStack(spacing: 20) {
                sizeItem("页图", TextbookFormat.bytes(totalPageBytes))
                sizeItem("批注", TextbookFormat.bytes(totalDrawingBytes))
                sizeItem("已下载教材", "\(booksWithLocalFiles.count) / \(books.count) 本")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func sizeItem(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 每本书

    private func bookRow(_ book: Textbook) -> some View {
        let pageBytes = bytesByBook[book.remoteID] ?? 0
        let drawingBytes = drawingBytesByBook[book.remoteID] ?? 0
        let stats = book.downloadStats

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(stats.done)/\(book.pageCount) 页已下载" +
                         (drawingBytes > 0 ? " · 批注 \(TextbookFormat.bytes(drawingBytes))" : ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Text(TextbookFormat.bytes(pageBytes))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    let removed = TextbookLibrary.removeLocalFiles(of: book, in: context)
                    refreshSizes()
                    Haptics.saved()
                    message = removed > 0
                        ? "已删除《\(book.name)》的本地页图，批注保留。"
                        : "《\(book.name)》本来就没有本地文件。"
                } label: {
                    Label("删本地页图", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(pageBytes == 0)

                Button(role: .destructive) {
                    pendingDelete = book
                } label: {
                    Label("删整本", systemImage: "trash.slash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
    }

    // MARK: - 量体积

    /// 量一遍本地占用。
    ///
    /// 放到后台队列做：`localBytes` 要遍历整个目录树，
    /// 下过几十本教材之后这是几百毫秒的事，放主线程会卡住滚动。
    private func refreshSizes() {
        isMeasuring = true
        let snapshot = books.map { (id: $0.remoteID, name: $0.name) }
        Task.detached(priority: .userInitiated) {
            var pageSizes: [Int: Int64] = [:]
            var drawingSizes: [Int: Int64] = [:]
            for item in snapshot {
                pageSizes[item.id] = TextbookStorage.localByteCount(
                    remoteID: item.id, name: item.name
                )
                drawingSizes[item.id] = TextbookStorage.drawingByteCount(
                    remoteID: item.id, name: item.name
                )
            }
            // ⚠️ 必须先把可变字典收成 `let` 再跨并发域。
            //    直接在 MainActor.run 里引用那两个 var，就是"在并发执行的代码里
            //    引用捕获的可变变量" —— Swift 6 下这是错误，现在也只是警告。
            let finalPageSizes = pageSizes
            let finalDrawingSizes = drawingSizes
            await MainActor.run {
                bytesByBook = finalPageSizes
                drawingBytesByBook = finalDrawingSizes
                isMeasuring = false
            }
        }
    }
}
