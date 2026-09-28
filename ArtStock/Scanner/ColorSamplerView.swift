//
//  ColorSamplerView.swift
//  ArtAssist — 美术生的工具箱
//
//  把取色控制器包进 SwiftUI。
//
//  界面上的格子线需要知道两件事：缓冲的像素尺寸、以及 preview 的 videoGravity。
//  所以帧回调把尺寸一起带上来，由界面用 ColorGridSampler.displayRect 算出
//  画面在视图里的实际位置 —— 画线和取样共用同一套坐标，才不会"线在这、色在那"。
//

import CoreVideo
import SwiftUI
import UIKit

// ⚠️ 必须是 `UIViewControllerRepresentable`，不是 `UIViewRepresentable`。
//    后者要求 `UIViewType: UIView`，而这里包的是 UIViewController ——
//    用错协议报出来的错是一句很难懂的
//    "type 'ColorSamplerView' does not conform to protocol 'UIViewRepresentable'"
//    + "protocol requires nested type 'UIViewType'"，跟真正的原因隔了十万八千里。
struct ColorSamplerView: UIViewControllerRepresentable {

    /// 每帧回调：(像素缓冲, 缓冲像素尺寸)。
    var onFrame: (CVPixelBuffer, CGSize) -> Void
    /// 手电筒等状态变化时通知界面刷新。
    var onStateChange: (() -> Void)? = nil
    /// 让界面能下发"开/关手电筒"。
    var controllerProxy: ColorSamplerProxy

    func makeUIViewController(context: Context) -> ColorSamplerViewController {
        let viewController = ColorSamplerViewController()
        viewController.onFrame = onFrame
        viewController.onStateChange = { [weak controllerProxy] in
            controllerProxy?.refresh(from: viewController)
            onStateChange?()
        }
        controllerProxy.attach(viewController)
        return viewController
    }

    func updateUIViewController(_ uiViewController: ColorSamplerViewController, context: Context) {
        uiViewController.onFrame = onFrame
    }
}

/// 让 SwiftUI 侧能读到相机状态、下发手电筒指令的小壳子。
///
/// 直接把 `ColorSamplerViewController` 交给 SwiftUI 观察是不行的
/// （UIViewController 不是 Observable），所以中间放一层。
@MainActor
@Observable
final class ColorSamplerProxy {

    private(set) var isTorchAvailable = false
    private(set) var isTorchOn = false
    private(set) var captureError: String?
    private(set) var isReady = false

    @ObservationIgnored private weak var controller: ColorSamplerViewController?

    func attach(_ controller: ColorSamplerViewController) {
        self.controller = controller
        refresh(from: controller)
    }

    func refresh(from controller: ColorSamplerViewController) {
        isTorchAvailable = controller.isTorchAvailable
        isTorchOn = controller.isTorchOn
        captureError = controller.captureError
        isReady = controller.captureError == nil
    }

    func toggleTorch() {
        controller?.toggleTorch()
    }
}
