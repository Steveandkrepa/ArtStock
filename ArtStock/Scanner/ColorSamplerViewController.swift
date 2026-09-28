//
//  ColorSamplerViewController.swift
//  ArtAssist — 美术生的工具箱
//
//  取色校准专用的取景控制器。
//
//  ── 为什么不复用 QRScannerViewController ─────────────────────
//  那个控制器是为"扫码 + OCR 认字"服务的，里面有一堆只服务于那两件事的东西
//  （元数据输出、高亮框、静态取景框、认字用的旋转策略）。
//  取色只需要"给我帧"，混在一起改会两头都容易坏 ——
//  扫码那条路刚修好，不值得为了省一个文件去动它。
//
//  这个控制器刻意做小：预览 + 视频帧 + 手电筒，没有别的。
//

import AVFoundation
import CoreVideo
import ImageIO
import UIKit

final class ColorSamplerViewController: UIViewController {

    /// 送一帧上来。参数是像素缓冲与它的像素尺寸。
    ///
    /// 尺寸要一起送，因为界面要按"缓冲的宽高比 + preview 的 videoGravity"
    /// 算出格子线画在哪 —— 画线和取样必须用同一套坐标。
    var onFrame: ((CVPixelBuffer, CGSize) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.artstock.sampler.session")
    private let videoQueue = DispatchQueue(label: "com.artstock.sampler.frames")

    private let videoOutput = AVCaptureVideoDataOutput()
    private var videoDevice: AVCaptureDevice?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var captureRotationObservation: NSKeyValueObservation?

    private var isConfigured = false
    private var isConfiguring = false

    /// 送帧间隔。取色比 OCR 便宜得多，可以快一点，但也没必要每帧都送。
    static let frameInterval: CFTimeInterval = 0.22
    private var lastFrameDispatch: CFTimeInterval = 0

    /// 手电筒状态（界面上的按钮读它）。
    private(set) var isTorchOn = false
    private(set) var isTorchAvailable = false
    /// 会话出错时的说明。
    private(set) var captureError: String?

    /// 状态变化回调。
    ///
    /// ⚠️ 标了 `@MainActor`：这个闭包会去写 SwiftUI 的可观察模型，
    /// 不标的话调用点就是"在非隔离上下文里调主线程隔离方法"，
    /// 报出来的错却是一句难懂的 "does not conform to protocol UIViewRepresentable"。
    var onStateChange: (@MainActor () -> Void)?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setUpPreviewLayer()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        requestAccessAndConfigure()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func setUpPreviewLayer() {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        // ⚠️ 这个值必须和界面上算格子线用的假设一致。
        //    界面按"铺满并裁掉多余"来算，这里就得是 resizeAspectFill。
        //    改成 resizeAspect 的话格子线会整体错位。
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    // MARK: - 权限与会话

    private func requestAccessAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else {
                    DispatchQueue.main.async {
                        self?.captureError = "没有相机权限。"
                        self?.onStateChange?()
                    }
                    return
                }
                self?.configureAndStart()
            }
        default:
            captureError = "相机权限被拒绝。到「设置」里打开，或者用「颜色库」手动改色值。"
            onStateChange?()
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                guard !self.isConfiguring else { return }
                self.isConfiguring = true
                let ok = self.configureSession()
                self.isConfiguring = false
                guard ok else { return }
                self.isConfigured = true
            }
            guard !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    private func configureSession() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video) else {
            DispatchQueue.main.async {
                self.captureError = "这台设备没有可用的摄像头。"
                self.onStateChange?()
            }
            return false
        }
        videoDevice = device

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                DispatchQueue.main.async {
                    self.captureError = "无法建立相机输入。"
                    self.onStateChange?()
                }
                return false
            }
            session.addInput(input)
        } catch {
            DispatchQueue.main.async {
                self.captureError = "相机初始化失败：\(error.localizedDescription)"
                self.onStateChange?()
            }
            return false
        }

        // videoSettings 必须在 addOutput 之前设置，否则不生效。
        // 32BGRA 是取色要的格式 —— ColorGridSampler 就是按 B、G、R、A 读的。
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        guard session.canAddOutput(videoOutput) else {
            DispatchQueue.main.async {
                self.captureError = "无法建立取色输出。"
                self.onStateChange?()
            }
            return false
        }
        session.addOutput(videoOutput)
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)

        DispatchQueue.main.async {
            self.setUpRotationCoordinator(for: device)
            self.isTorchAvailable = device.hasTorch && device.isTorchAvailable
            self.onStateChange?()
        }
        return true
    }

    private func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    // MARK: - 旋转

    /// 和扫码控制器同一套做法：用官方的 RotationCoordinator，
    /// 不要手写 `windowScene.interfaceOrientation` 的角度映射。
    ///
    /// 预览连接与送帧连接**必须同时转**：
    /// 只转预览的话，帧还是躺着的，采出来的 42 个格子会整片错位。
    private func setUpRotationCoordinator(for device: AVCaptureDevice) {
        guard let layer = previewLayer else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotationCoordinator = coordinator

        previewRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            DispatchQueue.main.async {
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                guard let connection = self?.previewLayer?.connection,
                      connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
            }
        }

        captureRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            DispatchQueue.main.async {
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                guard let self else { return }
                if let connection = self.videoOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }
        }
    }

    // MARK: - 手电筒

    func toggleTorch() {
        guard isTorchAvailable, let device = videoDevice else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try device.lockForConfiguration()
                let target = !device.isTorchActive
                if target, device.isTorchModeSupported(.on) {
                    try? device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                } else {
                    device.torchMode = .off
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.isTorchOn = device.isTorchActive
                    self.onStateChange?()
                }
            } catch {
                DispatchQueue.main.async {
                    self.captureError = "手电筒打不开：\(error.localizedDescription)"
                    self.onStateChange?()
                }
            }
        }
    }
}

// MARK: - 帧

extension ColorSamplerViewController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let onFrame else { return }

        let now = CACurrentMediaTime()
        guard now - lastFrameDispatch >= Self.frameInterval else { return }
        lastFrameDispatch = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        DispatchQueue.main.async {
            onFrame(pixelBuffer, size)
        }
    }
}
