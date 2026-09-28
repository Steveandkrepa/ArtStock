//
//  TaobaoOrdersView.swift
//  ArtAssist — 美术生的工具箱
//
//  淘宝账号管理 + 把网页上认到的订单文字变成"待收包裹"。
//
//  ── 这一页曾经很复杂，现在简单了 ─────────────────────────────
//  以前这里有：三条"猜接口"的抓取策略、策略日志、原始返回查看、
//  接口地址与版本号设置。它们的存在理由都是"App 自己去调淘宝接口"，
//  而那条路既不可靠（接口是逆向的），又带来了"账号身份从 cookie 算"
//  这个致命副作用（`cookie2` 连游客都有 → 出现账号 1、账号 2）。
//
//  现在读订单只有一条路，而且是用户看得见的那条：
//  **打开淘宝网页 → 翻到订单 → 截图认字 → 文字建包裹**。
//  所以这一页只剩两件事：管账号、进同步页。
//

import SwiftData
import SwiftUI

struct TaobaoOrdersView: View {

    let store: TaobaoSessionStore

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var isShowingLogin = false
    /// 网页同步（唯一读订单的入口）。
    @State private var isShowingWebSync = false
    @State private var message: String?
    /// 正在改名的账号 id（nil = 不显示改名弹窗）。
    @State private var renamingAccountID: String?
    @State private var newLabel = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    accountCard
                    if !store.isLoggedIn, store.activeAccount != nil { signedOutCard }
                    howItWorksCard
                }
                .padding(20)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }
            .artScrollEdgeEffect()
            .navigationTitle("淘宝账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $isShowingLogin) {
                TaobaoWebLoginView(store: store) {}
            }
            .sheet(isPresented: $isShowingWebSync) {
                TaobaoWebSyncView(store: store) { text in
                    // 认到的文字走**已有的**"粘贴订单文字"链路建包裹 ——
                    // 那条路的解析与匹配都测过，不需要另写一份。
                    importText(text)
                }
            }
            .alert("提示", isPresented: .presentWhen($message)) {
                Button("好") { message = nil }
            } message: {
                Text(message ?? "")
            }
        }
    }

    // MARK: 账号

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: store.isLoggedIn ? "person.crop.circle.badge.checkmark"
                                                : "person.crop.circle.badge.questionmark")
                    .font(.title2)
                    .foregroundStyle(store.isLoggedIn ? .green : .orange)

                VStack(alignment: .leading, spacing: 3) {
                    Text(currentAccountTitle)
                        .font(.headline)
                    Text(store.isLoggedIn
                         ? "读取订单只在你点「识别这一屏」时发生，不做轮询、不后台刷新。"
                         : "在 App 内的网页里登录，密码只输在淘宝自己的页面上。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)

                if let active = store.activeAccount {
                    Button("改名") {
                        renamingAccountID = active.id
                        newLabel = active.label
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }

            HStack(spacing: 10) {
                Button {
                    // 没登录就先登录，登录过就直接进同步页
                    if store.isLoggedIn {
                        isShowingWebSync = true
                    } else {
                        isShowingLogin = true
                    }
                } label: {
                    Label(store.isLoggedIn ? "打开淘宝网页识别订单" : "登录淘宝",
                          systemImage: store.isLoggedIn ? "safari" : "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .artProminentButton()
                .controlSize(.large)

                if store.isLoggedIn {
                    Button {
                        isShowingWebSync = true
                    } label: {
                        Label("同步", systemImage: "viewfinder")
                    }
                    .artGlassButton()
                    .controlSize(.large)

                    Button(role: .destructive) {
                        Task {
                            await store.logout()
                            message = "已退出登录：这份档案里的网页会话清干净了。"
                                + "账号记录和名字还在下面，重新登录还会记在同一个账号上。"
                        }
                    } label: {
                        Label("退出登录", systemImage: "person.badge.minus")
                    }
                    .artGlassButton()
                    .controlSize(.large)
                }
            }

            Button {
                // 新账号 = 一份全新的空档案，所以不需要清任何东西
                store.beginAddingAccount()
                isShowingLogin = true
            } label: {
                Label("添加另一个账号", systemImage: "person.badge.plus")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)

            if !store.accounts.isEmpty { accountList }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .alert("给这个账号起个名字", isPresented: .presentWhen($renamingAccountID)) {
            TextField("比如「我的号」「家人的号」", text: $newLabel)
            Button("保存") {
                if let id = renamingAccountID {
                    store.rename(accountID: id, to: newLabel)
                    Haptics.saved()
                }
                renamingAccountID = nil
            }
            Button("取消", role: .cancel) { renamingAccountID = nil }
        } message: {
            Text("只是本机上的备注，方便区分是哪个账号。")
        }
    }

    /// 有账号记录但登录状态没确认过。
    private var signedOutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("这个账号的登录状态是「未确认」")
                .font(.subheadline.weight(.medium))
            Text("登录态存在账号自己的浏览器档案里，不打开页面无法确认。"
                 + "点上面的按钮登录一次即可；如果它其实还登录着，"
                 + "同步页会直接显示订单页面。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var currentAccountTitle: String {
        guard let active = store.activeAccount else {
            return store.accounts.isEmpty ? "还没登录淘宝" : "当前没有选中的账号"
        }
        return store.isLoggedIn ? "已登录：\(active.displayName)"
                                : "当前账号：\(active.displayName)"
    }

    /// 已保存的账号列表。
    ///
    /// **每个账号一份独立的浏览器档案**（cookie、缓存都分开），
    /// 所以切换账号不用重新输密码，两个账号的登录态各自保留 ——
    /// 这也是"切换"两个字在这里的全部含义：决定当前用哪一份档案。
    private var accountList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("已保存的账号（\(store.accounts.count)）")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(store.accounts) { account in
                HStack(spacing: 10) {
                    Image(systemName: account.id == store.activeAccountID
                          ? "checkmark.circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(account.id == store.activeAccountID
                                         ? Theme.accent : Color.secondary)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.displayName)
                            .font(.subheadline)
                        Text(account.isSignedIn
                             ? "上次确认登录 \(Fmt.relative(account.signedInAt ?? account.savedAt))"
                             : "登录状态未确认")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer(minLength: 0)

                    if account.id != store.activeAccountID {
                        Button("切换") {
                            let ok = store.switchTo(accountID: account.id)
                            message = ok
                                ? "已切到「\(account.displayName)」。"
                                    + "点「打开淘宝网页识别订单」进去就是它的登录状态。"
                                : "切换失败：账号不在列表里了。"
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button {
                        renamingAccountID = account.id
                        newLabel = account.label
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("改名")

                    Button(role: .destructive) {
                        Task {
                            await store.removeAccount(id: account.id)
                            Haptics.alert()
                            message = "已删除「\(account.displayName)」，"
                                + "它的浏览器档案也清空了（里面没有任何会话残留）。"
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .tint(.red)
                }
                .padding(.vertical, 2)
            }

            Text("每个账号各有一份独立的浏览器档案（cookie、缓存都分开），"
                 + "所以切换不用重新输密码，两个账号的登录态各自保留。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 说明

    private var howItWorksCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "订单是怎么读进来的")

            bullet("1", "弹出淘宝自己的订单页面（用当前账号的档案，所以是已登录状态）")
            bullet("2", "你翻到订单那一屏（也可以在页面里点开某一单看详情）")
            bullet("3", "点「识别这一屏」——App 只是**截图认字**，不改动页面、不拦截请求")
            bullet("4", "认到的文字给你看一眼、能直接改，然后建成本地包裹")
            bullet("5", "到货时在「在途」里一键入库")

            Text("所以 App 不猜接口、不后台请求、不做轮询 —— "
                 + "淘宝改接口也不会让这个功能失效。代价是认字难免有错，"
                 + "所以文字摆出来让你改。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func bullet(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 16, alignment: .leading)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 行为

    /// 把**一段文字**（网页截图 OCR 出来的，或用户自己改过的）变成待收包裹。
    ///
    /// 和"粘贴订单文字"走的是同一条解析与匹配链路 —— 淘宝的商品标题
    /// 本来就是一行文本，跟用户粘贴的订单文本是同一种输入。
    private func importText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            message = "没认到文字。翻到订单内容占满屏幕的那一屏再认一次。"
            return
        }
        let catalog = IncomingPackageService.catalog(in: context)
        let package = IncomingPackageService.create(
            from: trimmed,
            catalog: catalog,
            in: context
        )
        try? context.save()
        Haptics.saved()
        if package.items.isEmpty {
            message = "这段文字里没认出商品条目。可以点「看 / 改文字」"
                + "把商品名改清楚一点再试。"
        } else {
            message = "已建好待收包裹：\(package.items.count) 条，其中 "
                + "\(package.matchedCount) 条匹配到了库里的东西。到「在途」里看。"
        }
    }
}
