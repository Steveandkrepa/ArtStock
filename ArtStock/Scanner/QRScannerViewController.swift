//
//  QRScannerViewController.swift
//  ArtAssist — 美术生的工具箱
//
//  AVFoundation 取景会话。选它而不是 VisionKit 的 DataScannerViewController 的原因：
//    · DataScannerViewController 需要 A12 及以上且只在真机可用，且无法在模拟器上给出可读提示；
//    · AVFoundation 可以在模拟器上优雅降级成"无相机 → 手输编码"；
//    · 我们需要完全控制连续扫描的去重逻辑与手电筒。
//
//  所有相机操作都在 sessionQueue 上执行，主线程只负责 UI 状态。
//

import AVFoundation
import ImageIO
import UIKit

final class QRScannerViewController: UIViewController {

    /// 识别到二维码时的回调：(原始内容, 符号类型 rawValue)。
    var onCode: ((String, String) -> Void)?

    /// 送一帧画面去认字。参数是像素缓冲与画面朝向。
    ///
    /// OCR 只在「认字」模式下才需要，所以由 `isEmittingFrames` 开关控制，
    /// 不用的时候一帧都不往上传，省电也省 CPU。
    var onFrame: ((CVPixelBuffer, CGImagePropertyOrientation) -> Void)?

    /// 是否正在送帧。
    ///
    /// ⚠️ 这个标记会被**视频队列读**、被**主线程写**。
    /// 用一个 Bool 是刻意的：它只有一个字，不存在读到"半个值"的问题，
    /// 而加锁或跳主线程在这里只会让丢帧逻辑变复杂、收益为零。
    var isEmittingFrames = false

    /// 送帧的最小间隔。中文 OCR 一帧要几百毫秒，送太快只会把队列堆满。
    static let frameInterval: CFTimeInterval = 1.1

    let controller: ScannerController

    // MARK: - 会话

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.artstock.scanner.session")
    private let metadataOutput = AVCaptureMetadataOutput()
    /// 视频数据输出：只为了拿帧给 Vision 认字，不做录制。
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "com.artstock.scanner.frames")
    private var lastFrameDispatch: CFTimeInterval = 0

    private var videoDevice: AVCaptureDevice?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    /// 官方旋转协调器。见 setUpRotationCoordinator 的说明。
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var captureRotationObservation: NSKeyValueObservation?
    private var isConfigured = false
    private var isConfiguring = false

    // MARK: - 视觉元素

    private let highlightView: UIView = {
        let view = UIView()
        view.layer.borderColor = UIColor.systemGreen.cgColor
        view.layer.borderWidth = 3
        view.layer.cornerRadius = 10
        view.layer.cornerCurve = .continuous
        view.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.16)
        view.isHidden = true
        return view
    }()

    /// 屏幕中央的静态取景提示框。
    private let reticleView: UIView = {
        let view = UIView()
        view.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        view.layer.borderWidth = 2
        view.layer.cornerRadius = 20
        view.layer.cornerCurve = .continuous
        view.backgroundColor = .clear
        return view
    }()

    // MARK: - Init

    init(controller: ScannerController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 未实现")
    }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setUpPreviewLayer()
        setUpOverlays()
        registerControllerActions()
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
        layoutOverlays()
        // 旋转不再在这里手动处理：RotationCoordinator 会持续跟随设备方向并
        // 自己更新 connection。见 setUpRotationCoordinator(for:)。
    }

    // MARK: - 视图搭建

    private func setUpPreviewLayer() {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    private func setUpOverlays() {
        view.addSubview(reticleView)
        view.addSubview(highlightView)
    }

    private func layoutOverlays() {
        let side = min(view.bounds.width, view.bounds.height) * 0.62
        reticleView.frame = CGRect(
            x: (view.bounds.width - side) / 2,
            y: (view.bounds.height - side) / 2,
            width: side,
            height: side
        )
        reticleView.layer.cornerRadius = 24
    }

    // MARK: - 控制通道

    private func registerControllerActions() {
        controller.startAction = { [weak self] in
            self?.startSession()
        }
        controller.stopAction = { [weak self] in
            self?.stopSession()
        }
        controller.toggleTorchAction = { [weak self] in
            self?.toggleTorch()
        }
    }

    // MARK: - 授权

    private func requestAccessAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            controller.authorization = .authorized
            configureAndStart()

        case .notDetermined:
            controller.authorization = .unknown
            // 外层闭包必须捕获 weak self，否则内层 DispatchQueue.main.async 里的
            // self 是非可选类型，`guard let self` 会报
            // "initializer for conditional binding must have Optional type"。
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.controller.authorization = .authorized
                        self.configureAndStart()
                    } else {
                        self.controller.authorization = .denied
                    }
                }
            }

        case .denied, .restricted:
            controller.authorization = .denied

        @unknown default:
            controller.authorization = .denied
        }
    }

    // MARK: - 会话配置

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                self.configureSession()
            }
            guard self.isConfigured else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            DispatchQueue.main.async {
                self.controller.isRunning = self.session.isRunning
            }
        }
    }

    /// - Note: 必须在 sessionQueue 上调用。
    private func configureSession() {
        guard !isConfiguring else { return }
        isConfiguring = true
        defer { isConfiguring = false }

        session.beginConfiguration()
        session.sessionPreset = .high

        // 优先后置广角，iPad 上如果没有后置就退回任意可用摄像头。
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video)

        guard let device else {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.controller.authorization = .unavailable
                self.controller.captureError = "未检测到可用摄像头"
            }
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw ScannerSetupError.cannotAddInput }
            session.addInput(input)
            videoDevice = device
        } catch {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.controller.captureError = "无法打开摄像头：\(error.localizedDescription)"
            }
            return
        }

        guard session.canAddOutput(metadataOutput) else {
            session.commitConfiguration()
            DispatchQueue.main.async {
                self.controller.captureError = "无法建立识别输出"
            }
            return
        }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: .main)

        // ── 视频数据输出（给 OCR 用）──
        //
        // videoSettings 必须在 addOutput **之前**设置，否则不生效 ——
        // 这是 AVFoundation 的一个经典坑，设晚了会拿到默认格式（可能是 YUV），
        // Vision 能处理的格式就少了。
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        }

        // 只订阅真正支持的符号类型，否则 setMetadataObjectTypes 会抛异常。
        let wanted: [AVMetadataObject.ObjectType] = [
            .qr, .ean13, .ean8, .upce, .code128, .code39, .code93, .itf14,
            .pdf417, .aztec, .dataMatrix
        ]
        let supported = wanted.filter { metadataOutput.availableMetadataObjectTypes.contains($0) }
        metadataOutput.metadataObjectTypes = supported.isEmpty
            ? metadataOutput.availableMetadataObjectTypes
            : supported

        session.commitConfiguration()
        isConfigured = true

        DispatchQueue.main.async {
            self.setUpRotationCoordinator(for: device)
            self.controller.isTorchAvailable = device.hasTorch && device.isTorchAvailable
        }
    }

    // MARK: - 启停

    private func startSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
            DispatchQueue.main.async { self.controller.isRunning = self.session.isRunning }
        }
    }

    private func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            // 关掉手电筒再停会话，避免退出后灯还亮着。
            if let device = self.videoDevice, device.hasTorch, device.torchMode != .off {
                try? device.lockForConfiguration()
                device.torchMode = .off
                device.unlockForConfiguration()
            }
            self.session.stopRunning()
            DispatchQueue.main.async {
                self.controller.isRunning = false
                self.controller.isTorchOn = false
            }
        }
    }

    // MARK: - 手电筒

    private func toggleTorch() {
        sessionQueue.async { [weak self] in
            guard let self,
                  let device = self.videoDevice,
                  device.hasTorch,
                  device.isTorchAvailable else { return }

            let turningOn = device.torchMode == .off
            do {
                try device.lockForConfiguration()
                device.torchMode = turningOn ? .on : .off
                device.unlockForConfiguration()
                DispatchQueue.main.async {
                    self.controller.isTorchOn = turningOn
                }
            } catch {
                DispatchQueue.main.async {
                    self.controller.captureError = "手电筒不可用：\(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - 旋转

    /// 用 Apple 官方的 `RotationCoordinator` 把预览与识别都对齐到设备方向。
    ///
    /// ⚠️ 这里修过一个"画面方向不对"的 bug，记录清楚免得改回去：
    ///
    /// 早先版本**刻意没用** `RotationCoordinator`，而是自己按
    /// `windowScene.interfaceOrientation` 硬映射角度（portrait→90、landscapeLeft→0 …）。
    /// 那个映射只考虑了"界面方向"，漏掉了两个同样决定角度的因素：
    ///
    ///   · **摄像头位置** —— 前置传感器是镜像的，角度与后置不同；
    ///   · **iPad 上窗口不一定跟着设备转** —— Stage Manager / 分屏下
    ///     `interfaceOrientation` 和真实握持方向可以完全不一致。
    ///
    /// 手写映射要覆盖这些组合非常容易漏，而且错了**不报错、只表现为画面歪掉**，
    /// 所以极难自测发现。
    ///
    /// `AVCaptureDevice.RotationCoordinator`（iOS 17.0+，正好是本工程的最低版本）
    /// 就是为这件事提供的，它会同时给出**预览**和**采集**各自该用的角度，
    /// 还带"水平线对齐"（用户把设备端歪一点时画面不会跟着倒）。
    ///
    /// 两个 connection 都要设：
    /// 预览决定画面正不正；采集决定高亮框的位置 ——
    /// 只设前者的后果是"画面是正的，但框歪着"。
    private func setUpRotationCoordinator(for device: AVCaptureDevice) {
        guard let previewLayer else { return }

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator

        // 预览：跟水平线对齐
        previewRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            // KVO 回调可能在任意线程；读属性与改 connection 都放回主线程做。
            DispatchQueue.main.async {
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                guard let connection = self?.previewLayer?.connection,
                      connection.isVideoRotationAngleSupported(angle) else { return }
                connection.videoRotationAngle = angle
            }
        }

        // 采集：高亮框位置依赖它
        captureRotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            DispatchQueue.main.async {
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                guard let self else { return }
                if let connection = self.metadataOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
                // 送帧连接也要一起转 —— 否则 OCR 拿到的是躺着的画面，中文一行都读不出来。
                if let frameConnection = self.videoOutput.connection(with: .video),
                   frameConnection.isVideoRotationAngleSupported(angle) {
                    frameConnection.videoRotationAngle = angle
                }
            }
        }
    }

    // MARK: - 高亮

    private func showHighlight(_ rect: CGRect) {
        highlightView.frame = rect.insetBy(dx: -6, dy: -6)
        highlightView.isHidden = false

        UIView.animate(withDuration: 0.15) {
            self.highlightView.alpha = 1
        } completion: { _ in
            UIView.animate(withDuration: 0.45, delay: 0.25) {
                self.highlightView.alpha = 0
            } completion: { _ in
                self.highlightView.isHidden = true
                self.highlightView.alpha = 1
            }
        }
    }
}

// MARK: - 元数据回调

// MARK: - 视频帧（OCR 用）

extension QRScannerViewController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // 没开认字模式就一帧都不处理。
        guard isEmittingFrames, let onFrame else { return }

        // 限流：中文 OCR 慢，送太快只会让 isBusy 闸一直丢帧，白烧电。
        let now = CACurrentMediaTime()
        guard now - lastFrameDispatch >= Self.frameInterval else { return }
        lastFrameDispatch = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 连接已经被 RotationCoordinator 转过角度了，所以缓冲本身已经是"正"的。
        // （真机上如果中文死活认不出来，第一个要查的就是这里和上面的旋转同步。）
        DispatchQueue.main.async {
            onFrame(pixelBuffer, .up)
        }
    }
}

extension QRScannerViewController: AVCaptureMetadataOutputObjectsDelegate {

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let payload = object.stringValue,
              !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // 把识别框从"设备坐标系"换算到"预览层坐标系"。
        if let transformed = previewLayer?.transformedMetadataObject(for: object) as? AVMetadataMachineReadableCodeObject {
            showHighlight(transformed.bounds)
        }

        onCode?(payload, object.type.rawValue)
    }
}

// MARK: - 错误

private enum ScannerSetupError: LocalizedError {
    case cannotAddInput

    var errorDescription: String? {
        switch self {
        case .cannotAddInput: return "摄像头输入无法加入会话"
        }
    }
}
