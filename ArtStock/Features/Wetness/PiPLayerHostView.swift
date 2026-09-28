//
//  PiPLayerHostView.swift
//  ArtAssist — 美术生的工具箱
//
//  把画中画用的 `AVSampleBufferDisplayLayer` 挂进视图层级。
//
//  ── 为什么必须有这个文件 ─────────────────────────────────────
//  `AVPictureInPictureController` 要求它的内容来源（sample buffer display layer）
//  **已经在一个屏幕上的窗口里**。layer 只是被创建、往里喂了数据，但不在任何
//  view 的 layer tree 里的话，`startPictureInPicture()` 会直接走
//  `failedToStartPictureInPictureWithError`，界面上表现为"点了没任何反应"。
//
//  这正是本工程实测踩过的坑 —— 原来 PiP 控制器自己 new 了一个 layer 就往里写，
//  从没挂到界面上，所以画中画永远起不来。
//
//  现在这个 layer 被放在计时卡片里的一个小预览区里：
//  既满足"必须在窗口里"的要求，又顺带让用户看见"悬浮窗里会显示什么"。
//

import AVFoundation
import SwiftUI
import UIKit

/// 承载 display layer 的 UIView。layer 尺寸跟着视图走。
final class LayerHostingView: UIView {

    override func layoutSubviews() {
        super.layoutSubviews()
        // display layer 不会自动跟随 autoresizing，手动同步尺寸。
        layer.sublayers?.forEach { sublayer in
            CATransaction.begin()
            CATransaction.setDisableActions(true)   // 关掉隐式动画，避免缩放时糊一下
            sublayer.frame = bounds
            CATransaction.commit()
        }
    }
}

struct PiPLayerHostView: UIViewRepresentable {

    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> LayerHostingView {
        let view = LayerHostingView()
        view.backgroundColor = .black
        view.layer.cornerRadius = 10
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        // 关键一步：把 layer 挂进视图层级。
        view.layer.addSublayer(displayLayer)
        displayLayer.frame = view.bounds
        displayLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: LayerHostingView, context: Context) {
        displayLayer.frame = uiView.bounds
    }
}
