//
//  QRScannerView.swift
//  ArtAssist — 美术生的工具箱
//
//  把 AVFoundation 取景控制器包进 SwiftUI。
//
//  除了条码，还往上送**视频帧**给 OCR 认字用 —— 见 `wantsFrames`。
//

import CoreVideo
import ImageIO
import SwiftUI

struct QRScannerView: UIViewControllerRepresentable {

    /// 相机状态与控制通道。
    let controller: ScannerController

    /// 是否送视频帧上来（认字模式才需要）。
    ///
    /// 默认 false：扫码不用帧，白送只会白烧电。
    var wantsFrames: Bool = false

    /// 识别到二维码时回调（主线程）。
    let onCode: (String, String) -> Void

    /// 每个（限流后的）视频帧回调一次，主线程。
    var onFrame: ((CVPixelBuffer, CGImagePropertyOrientation) -> Void)?

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let viewController = QRScannerViewController(controller: controller)
        viewController.onCode = onCode
        viewController.onFrame = onFrame
        viewController.isEmittingFrames = wantsFrames
        return viewController
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        // 闭包可能随视图重建而变化，每次更新都重新挂上，避免捕获旧的 model。
        uiViewController.onCode = onCode
        uiViewController.onFrame = onFrame
        uiViewController.isEmittingFrames = wantsFrames
    }
}
