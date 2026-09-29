//
//  LogisticsQueryView.swift
//  ArtAssist — 美术生的工具箱
//
//  物流详情：打开**快递100 网页版**的查询页，显示包裹位置与物流轨迹。
//
//  ── 为什么用网页而不是接口 ─────────────────────────────────
//  快递轨迹接口需要各家快递/快递100 的付费 key，还要处理签名与合规；
//  App 不做后台轮询、不持有任何物流接口密钥。网页版查询免费、无需登录，
//  跟"淘宝也是打开网页"是同一套思路 —— 用户看得到真实来源，也不用担心
//  物流信息被 App 上传到别处。
//

import SwiftUI
import WebKit

/// 用快递100 网页版查一个包裹的物流详情。
///
/// 有承运商时带 `com` 参数直达对应快递的查询页；认不出承运商时
/// 只给单号，让快递100 自动识别。
struct LogisticsQueryView: View {

    let trackingNumber: String
    var carrierName = ""

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LogisticsWebView(url: Self.queryURL(
                trackingNumber: trackingNumber,
                carrierName: carrierName
            ))
            .navigationTitle("物流详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    /// 拼快递100 查询地址。
    ///
    /// 实测三种写法都可达（200）：
    ///   `/?nu=…`、`/?com=…&nu=…`、`/chaxun?com=…&nu=…`（后者 302 到详情页）。
    /// 统一走 `/?…` 首页查询，避免依赖详情页的跳转路径。
    static func queryURL(trackingNumber: String, carrierName: String) -> URL? {
        var components = URLComponents(string: "https://www.kuaidi100.com/")
        var items = [URLQueryItem(name: "nu", value: trackingNumber)]
        if let code = carrierCode(for: carrierName) {
            items.append(URLQueryItem(name: "com", value: code))
        }
        components?.queryItems = items
        return components?.url
    }

    /// 承运商名 → 快递100 的 `com` 参数。
    ///
    /// 覆盖本地 `TrackingNumberParser` 能认出的那几家；认不出返回 nil，
    /// 查询页会自动识别单号。
    static func carrierCode(for name: String) -> String? {
        let text = name.lowercased()
        let table: [(keywords: [String], code: String)] = [
            (["顺丰", "sf"], "shunfeng"),
            (["京东", "jd"], "jd"),
            (["极兔", "jt"], "jtexpress"),
            (["圆通", "yt"], "yuantong"),
            (["中通", "zto", "zhongtong"], "zhongtong"),
            (["申通", "sto"], "shentong"),
            (["韵达", "yd"], "yunda"),
            (["德邦", "dbl", "dop"], "debangkuaidi"),
            (["ems"], "ems"),
            (["邮政"], "youzhengguonei"),
        ]
        for entry in table where entry.keywords.contains(where: { text.contains($0) }) {
            return entry.code
        }
        return nil
    }
}

/// 干净的 WKWebView：不注入、不拦截，只加载快递100 查询页。
private struct LogisticsWebView: UIViewRepresentable {

    let url: URL?

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        // 与淘宝页保持一致：用标准 iPad Safari UA，避免被降级成手机版
        webView.customUserAgent = "Mozilla/5.0 (iPad; CPU OS 18_7 like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 "
            + "Mobile/15E148 Safari/604.1"
        if let url {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
