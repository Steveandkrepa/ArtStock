//
//  TaobaoWebLoginView.swift
//  ArtAssist — 美术生的工具箱
//
//  在 App 内的网页里登录淘宝 —— 密码只输在淘宝自己的页面上。
//
//  ── 登录成功怎么判断（换过一次做法）───────────────────────────
//  旧做法：登录完成后去 WebView 的 cookie 罐里捞 `unb` / `cookie2`，
//  捞到就算成功。**这是错的**：`cookie2` 连**匿名访客**都有，
//  于是"还没登录"的游客页也能被判成登录成功，还顺手把访客存成了一个
//  "账号 1" —— 等真的登录完成、`unb` 出现，就成了**账号 2**。
//
//  现在的做法：**看页面**（`TaobaoLoginDetector`）。
//  还停在 `login.taobao.com`、标题写着「登录淘宝」，就是没登录；
//  已经跳到淘宝/天猫的正常页面，就是登录了。页面不会骗人。
//
//  登录用的是**这个账号自己的浏览器档案**（`WKWebsiteDataStore(forIdentifier:)`），
//  所以新账号天然是一份空档案，不需要清任何东西，也不会串到别的账号。
//

import SwiftUI
import WebKit

struct TaobaoWebLoginView: View {

    let store: TaobaoSessionStore
    var onSuccess: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var statusText = "请在下方登录淘宝账号"
    /// 这次登录用哪份档案。在 `onAppear` 里定下来 —— 一旦开始登录就不能再变，
    /// 否则登录完成的记录会挂到另一个档案上。
    @State private var identifier: UUID?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                if let identifier {
                    TaobaoWebView(
                        startURL: URL(string: TaobaoWebEndpoint.loginPage)!,
                        dataStore: WKWebsiteDataStore(forIdentifier: identifier)
                    ) { url, title in
                        handlePageLoaded(url: url, title: title, identifier: identifier)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("登录淘宝")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("我已登录完成") {
                        // 兜底：自动判断不灵时手动确认
                        guard let identifier else { return }
                        finish(identifier: identifier)
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                if identifier == nil { identifier = store.loginStoreIdentifier() }
            }
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusText)
                .font(.subheadline.weight(.medium))
            Text("登录在你面前的淘宝页面上完成，App 不接触密码。"
                 + "登录完成后会自动返回，账号会用一份**独立的浏览器档案**保存，"
                 + "与其它账号互不影响。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: 行为

    /// 页面加载完成 —— 顺便判断是不是已经登录了。
    private func handlePageLoaded(url: URL?, title: String?, identifier: UUID) {
        if TaobaoLoginDetector.looksLoggedIn(url: url, title: title) {
            finish(identifier: identifier)
        } else {
            statusText = title.map { "当前页面：\($0)" } ?? "等待登录完成…"
        }
    }

    private func finish(identifier: UUID) {
        let id = store.registerLogin(identifier: identifier)
        statusText = "已登录，账号已保存"
        Haptics.saved()
        onSuccess()
        // 记下 id 只是为了让这个局部变量有去处；真正重要的是 store 已更新
        _ = id
        dismiss()
    }
}

// MARK: - WebView

/// 包一层 `WKWebView`：每次页面加载完成时把 URL 和标题交回来。
private struct TaobaoWebView: UIViewRepresentable {

    let startURL: URL
    /// 用哪个浏览器档案登录。每个账号一份，天然隔离。
    let dataStore: WKWebsiteDataStore
    /// 页面加载完成：(url, title)。
    var onLoaded: (URL?, String?) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // 这个账号自己的持久档案：登录状态重启后还在，且各账号互不可见
        configuration.websiteDataStore = dataStore
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (iPad; CPU OS 18_7 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        webView.load(URLRequest(url: startURL))
        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLoaded = onLoaded
    }

    func makeCoordinator() -> Coordinator { Coordinator(onLoaded: onLoaded) }

    final class Coordinator: NSObject, WKNavigationDelegate {

        weak var webView: WKWebView?
        var onLoaded: (URL?, String?) -> Void

        init(onLoaded: @escaping (URL?, String?) -> Void) {
            self.onLoaded = onLoaded
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            report(from: webView)
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            report(from: webView)
        }

        /// 页面加载告一段落。
        ///
        /// 淘宝登录后面还有几次前端跳转，`didFinish` 会多次触发 ——
        /// 所以这里不做去重，交给上面按"当前页面像不像登录页"来判断。
        private func report(from webView: WKWebView) {
            let url = webView.url
            let title = webView.title
            DispatchQueue.main.async { [onLoaded] in
                onLoaded(url, title)
            }
        }
    }
}
