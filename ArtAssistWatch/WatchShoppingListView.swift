//
//  WatchShoppingListView.swift
//  ArtAssist — 美术生的工具箱（Apple Watch 端）
//
//  采购清单：在美术用品店里对着划掉。
//
//  ── 为什么这件小事值得放在表上 ───────────────────────────────
//  在店里一只手拿画纸/试笔，另一只手划清单 —— 掏 iPad 是不现实的。
//  而"该买什么"这件事本身很短，一屏就看完了。
//
//  ⚠️ 清单**只存在手表上**，不会同步回 iPad。这不是偷懒：
//     跨设备同步要 App Group 或 WatchConnectivity，本项目刻意不用
//     任何 entitlement（免费 Apple ID 签不了），而且 iPad 上根本没有
//     WCSession。所以宁可说清楚"这是表上的清单"，
//     也不做一个和 iPad 对不上、让人以为同步了的假象。
//

import Foundation
import Observation
import SwiftUI
import WatchKit

struct WatchShoppingItem: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var isDone = false
    var addedAt = Date()
}

@MainActor
@Observable
final class WatchShoppingStore {

    private(set) var items: [WatchShoppingItem] = []

    /// 输入新条目用的草稿。
    var draftName = ""

    private static let key = "watch.shopping.items"

    init() {
        restore()
    }

    var pendingCount: Int { items.filter { !$0.isDone }.count }

    /// 未买的排前面（店里要看的正是这些），同组内按加入时间倒序。
    var ordered: [WatchShoppingItem] {
        items.sorted { lhs, rhs in
            if lhs.isDone != rhs.isDone { return !lhs.isDone }
            return lhs.addedAt > rhs.addedAt
        }
    }

    // MARK: - 增删改

    @discardableResult
    func add(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // 同名的没买过的就不重复加了 —— 在店里重复点两下很常见
        if items.contains(where: { !$0.isDone && $0.name == trimmed }) { return false }
        items.append(WatchShoppingItem(name: trimmed))
        persist()
        return true
    }

    func toggle(_ item: WatchShoppingItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isDone.toggle()
        persist()
        // 划掉时给一下触感 —— 手上有东西时这一下反馈很重要
        WKInterfaceDevice.current().play(items[index].isDone ? .success : .click)
    }

    func delete(_ item: WatchShoppingItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func delete(at offsets: IndexSet) {
        let orderedItems = ordered
        let ids = offsets.compactMap { index -> UUID? in
            guard orderedItems.indices.contains(index) else { return nil }
            return orderedItems[index].id
        }
        items.removeAll { ids.contains($0.id) }
        persist()
    }

    /// 把已经买到的清掉。
    func clearDone() {
        items.removeAll { $0.isDone }
        persist()
    }

    // MARK: - 落盘

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let restored = try? JSONDecoder().decode([WatchShoppingItem].self, from: data)
        else { return }
        items = restored
    }
}

struct WatchShoppingListView: View {

    // ⚠️ 必须用 @Bindable 而不是 let：
    //    `@Observable` 对象只有通过 @Bindable 才能取出 $ 绑定
    //    （温湿度滑块、草稿输入框都要双向绑定）。
    @Bindable var store: WatchShoppingStore

    @State private var isAdding = false
    @FocusState private var addFieldFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                if store.items.isEmpty {
                    Text("还没有要买的。点右上角加一条，或者用语音输入。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                ForEach(store.ordered) { item in
                    Button {
                        store.toggle(item)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.isDone ? .green : .secondary)
                            Text(item.name)
                                .strikethrough(item.isDone)
                                .foregroundStyle(item.isDone ? .secondary : .primary)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { store.delete(at: $0) }

                if store.items.contains(where: \.isDone) {
                    Button("清除已买到的") { store.clearDone() }
                        .font(.footnote)
                }
            }
            .navigationTitle("采购清单")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.draftName = ""
                        isAdding = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加")
                }
            }
            .sheet(isPresented: $isAdding) { addSheet }
        }
    }

    private var addSheet: some View {
        NavigationStack {
            VStack(spacing: 8) {
                TextField("画材名，如「4K 素描纸」", text: $store.draftName)
                    .focused($addFieldFocused)
                    .onSubmit(commit)
                Button("加入清单", action: commit)
                    .disabled(store.draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 4)
            .navigationTitle("买什么")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { isAdding = false }
                }
            }
            .onAppear { addFieldFocused = true }
        }
    }

    private func commit() {
        guard store.add(store.draftName) else {
            // 名字为空、或已经在清单里了 —— 都直接关掉，不弹错误框，
            // 表上弹窗打断感太强
            isAdding = false
            return
        }
        store.draftName = ""
        isAdding = false
    }
}
