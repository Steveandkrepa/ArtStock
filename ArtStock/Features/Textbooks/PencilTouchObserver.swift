//
//  PencilTouchObserver.swift
//  ArtAssist — 美术生的工具箱
//
//  **主动判断"这一下是 Apple Pencil 还是手指"。**
//
//  ── 为什么要主动检测 ─────────────────────────────────────────
//  阅读器的分工是「笔用来画、手指用来翻页」。但原来只能靠用户先点一下
//  屏上的「批注」按钮切模式 —— 手里已经拿着笔了还要先去点个按钮，很别扭。
//
//  `UITouch.type` 是系统给的可靠判据：
//    · `.pencil` —— Apple Pencil（以及少数明确声明支持的第三方笔）
//    · `.direct` —— 手指
//  所以在笔**第一次碰到屏幕**时就能认出它，顺手把批注模式打开。
//
//  ── 为什么用"故意失败"的手势识别器 ───────────────────────────
//  用一层透明 UIView 去接 `touchesBegan` 会把触摸从下层抢走，
//  翻页和缩放就废了。而一个**收到触摸就立刻置 `.failed`** 的手势识别器：
//    · 能看到 `UITouch.type`（手势识别器比视图更早拿到触摸）
//    · 一旦失败就什么都不消费，这次触摸原样交给下面的视图和其它手势
//  这是 UIKit 里唯一"只看不打扰"的观察方式。
//
//  ⚠️ 识别器挂在 window 上，所以离开这个页面时必须**摘掉** ——
//     不摘的话它会在整个 App 里继续收触摸（别的页面用笔也会被当成
//     "要开始批注"）。
//

import SwiftUI
import UIKit

/// 只看不消费的 Pencil 触摸观察者。
final class PencilTouchObserver: UIGestureRecognizer {

    /// 检测到 Apple Pencil 落笔时回调（每次落笔都会调，调用方自己去重）。
    var onPencilTouch: (() -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        // 我们永远不会"识别成功"，所以这两个开关只影响语义，不影响行为；
        // 显式关掉，表明不会取消或延迟任何触摸。
        cancelsTouchesInView = false
        delaysTouchesBegan = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if touches.contains(where: { $0.type == .pencil }) {
            onPencilTouch?()
        }
        // ⚠️ 立刻失败：这次触摸不归我们，交还给下面的视图和别的手势识别器。
        state = .failed
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }
}

/// 把 `PencilTouchObserver` 挂到窗口上的小视图。
///
/// 零尺寸、不吃触摸；只负责在出现/消失时把识别器挂上/摘下。
struct PencilTouchObserverView: UIViewRepresentable {

    /// 检测到 Apple Pencil 时调用。
    var onPencilTouch: () -> Void

    func makeUIView(context: Context) -> ObserverHostView {
        let view = ObserverHostView()
        view.isUserInteractionEnabled = false
        view.observer.onPencilTouch = onPencilTouch
        return view
    }

    func updateUIView(_ uiView: ObserverHostView, context: Context) {
        uiView.observer.onPencilTouch = onPencilTouch
    }

    final class ObserverHostView: UIView {

        let observer = PencilTouchObserver()
        /// 记住挂到哪个窗口上，离开时好摘掉。
        private weak var attachedWindow: UIWindow?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window {
                guard attachedWindow !== window else { return }
                // 换窗口（或第一次出现）：先摘旧的再挂新的
                attachedWindow?.removeGestureRecognizer(observer)
                window.addGestureRecognizer(observer)
                attachedWindow = window
            } else {
                // 离开视图层级 —— 必须摘掉，否则它在别的页面继续吃触摸
                attachedWindow?.removeGestureRecognizer(observer)
                attachedWindow = nil
            }
        }
    }
}
