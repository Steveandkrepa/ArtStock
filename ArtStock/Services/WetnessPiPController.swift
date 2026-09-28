//
//  WetnessPiPController.swift
//  ArtAssist — 美术生的工具箱
//
//  把"还剩多久该喷水、喷几下"做成一个悬浮窗口，一直浮在别的 App 上面 ——
//  画画的时候在 Procreate 里，不切回来也能看见。
//
//  ── 为什么只能这么做 ─────────────────────────────────────────
//  PiP 的正常用途是视频。要让**任意内容**（这里是几个数字）进 PiP，
//  唯一的路子是 `AVPictureInPictureController.ContentSource(
//      sampleBufferDisplayLayer:playbackDelegate:)`（iOS 15+）：
//  自己把画面渲染成 `CMSampleBuffer` 喂给 `AVSampleBufferDisplayLayer`。
//  所以这里有一条手动渲染管线：SwiftUI → UIImage → CVPixelBuffer → CMSampleBuffer。
//
//  另一个选项 Live Activity 在 iPad 上不可用（那是 iPhone 锁屏/灵动岛的东西），
//  所以对 iPad 来说 PiP 是唯一能做到"悬浮常驻"的手段。
//
//  ── 免费 Apple ID 下能用吗 ────────────────────────────────────
//  能。需要的是 Info.plist 里的 `UIBackgroundModes = [audio]`，
//  那是 plist 键、**不是 entitlement**，SideStore 自签不受影响。
//  （本工程的 Resources/Info.plist 已声明。）
//
//  ── ⚠️ 未在本机验证的部分 ───────────────────────────────────
//  这个环境没有真机也没有模拟器 runtime，所以以下两件事我**没能实测**：
//    · PiP 窗口在 App 完全切到后台后能否持续存活
//    · 在 LiveContainer 里的实际表现
//  代码按 Apple 的要求做了（音频会话 + audio 后台模式），但如果真机上
//  PiP 一进后台就消失，那就是音频会话这一段需要再调 —— 见 `activateAudioSession`。
//
//  ── 已经堵掉的三个"静默失败" ─────────────────────────────────
//  PiP 失败时系统**不会**抛异常，也不会自己弹提示，所以之前的表现是
//  "点了没反应"。这条链路上有三个地方会安静地什么都不发生，现在都堵上了：
//    1. display layer 没挂进视图层级     → PiPLayerHostView 负责挂，启动前检查
//    2. 像素缓冲没有 IOSurface 支撑      → 黑屏但不报错，已加 IOSurface 键
//    3. isPictureInPicturePossible 竞态  → 原来一次性判断，现在 300ms 重试 10 次
//  另外每次失败都会通过 onError 冒到界面上，不会再无声无息。
//

import AVFoundation
import AVKit
import Foundation
import Observation
import SwiftUI
import UIKit

// MARK: - 要显示的内容

/// 画中画窗口里显示的东西。刻意做得极少 —— PiP 窗口很小，多一个字都是噪声。
struct PiPContent: Equatable, Sendable {
    /// 例如「群青 · 密闭调色盒」
    var title: String
    /// 倒计时文本，例如「2:14」或「已超 8 分」
    var timeText: String
    /// 建议喷雾下数。0 表示还没标定。
    var sprays: Int
    /// 紧急程度 0–1，用来决定配色。
    var urgency: Double
    /// 是否已经超过建议补水时刻。
    var isOverdue: Bool

    static let placeholder = PiPContent(
        title: "等待开始", timeText: "--:--", sprays: 0, urgency: 0, isOverdue: false
    )
}

// MARK: - 控制器

@MainActor
@Observable
final class WetnessPiPController: NSObject {

    private(set) var isActive = false
    /// 正在启动中（含重试窗口期）。按钮据此显示"正在启动…"，避免用户以为没反应。
    private(set) var isStarting = false
    private(set) var lastError: String?

    /// 设备是否支持画中画。iPad 都支持；模拟器上通常为 false。
    static var isSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    @ObservationIgnored private var pipController: AVPictureInPictureController?

    /// ⚠️ 这个 layer **必须被挂进视图层级**（见 PiPLayerHostView），
    ///    否则 PiP 永远起不来 —— 而且失败是静默的，界面上"点了没反应"。
    ///    这是实测踩过的坑：原先把 layer 建出来只往里喂数据、没往任何 view 里放，
    ///    结果 startPictureInPicture() 直接走 failedToStart 而用户看不到任何提示。
    @ObservationIgnored let displayLayer = AVSampleBufferDisplayLayer()

    /// 启动/运行失败时回调给界面。之前没有这条通路，错误全被吞掉。
    @ObservationIgnored var onError: ((String) -> Void)?
    /// 状态变化回调（供界面刷新按钮文案）。
    @ObservationIgnored var onActiveChanged: ((Bool) -> Void)?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    /// 每帧递增。用固定 PTS 反复入队时，display layer 有时不会刷新。
    @ObservationIgnored private var frameIndex: Int64 = 0
    /// 当前内容的取值闭包，由界面提供 —— 这样倒计时会实时走。
    @ObservationIgnored private var contentProvider: (() -> PiPContent)?
    /// 启动重试计数。见 attemptStart()。
    @ObservationIgnored private var startRetries = 0
    /// 连续渲染失败次数，用于只报一次错。
    @ObservationIgnored private var renderFailureCount = 0
    /// 最多重试几次。300ms × 10 ≈ 3 秒，足够等过窗口期又不会让用户干等。
    private static let maxStartRetries = 10

    /// PiP 的渲染尺寸。16:9 是 PiP 的常见比例，480×270 足够清晰又不浪费。
    private static let renderSize = CGSize(width: 480, height: 270)

    // MARK: - 启停

    /// 开始画中画。
    /// - Parameter content: 每次刷新时调用，返回当前要显示的内容。
    /// - Returns: 是否成功启动。
    @discardableResult
    func start(content: @escaping () -> PiPContent) -> Bool {
        lastError = nil
        contentProvider = content

        guard Self.isSupported else {
            lastError = "这台设备不支持画中画。"
            return false
        }

        if pipController == nil {
            guard setUpController() else { return false }
        }

        guard pipController != nil else {
            report("画中画控制器没有建起来。")
            return false
        }

        // ⚠️ 顺序有讲究：
        //   1. 先开音频会话 —— 系统在决定"能不能起 PiP"时会看 App 有没有
        //      后台存活能力，会话没激活时 isPictureInPicturePossible 可能是 false。
        //   2. 再喂第一帧 —— 空 layer 启动会闪白，而且可能被判定为"没有内容"。
        //   3. 最后才 startPictureInPicture()，且必须在前台调用。
        activateAudioSession()
        render(content: content())
        startUpdateLoop()

        startRetries = 0
        isStarting = true
        attemptStart()
        return true
    }

    /// 尝试启动 PiP。
    ///
    /// **为什么要重试**：`isPictureInPicturePossible` 在 layer 刚挂上、
    /// 或音频会话刚激活的那一瞬间经常还是 false，等几百毫秒才变 true。
    /// 之前这里是一次性判断 —— 一旦撞上那个窗口期就直接报"系统不允许"，
    /// 表现就是"点了没反应"。
    private func attemptStart() {
        guard let pipController else { return }

        // layer 必须已经在窗口里。没挂上就重试，重试完还不成就明确告诉用户 ——
        // 而不是静默失败。
        if displayLayer.superlayer == nil {
            guard startRetries < Self.maxStartRetries else {
                report("画中画的画面层没能挂到界面上（看下面那块预览区有没有显示出来）。")
                return
            }
            retryStart()
            return
        }

        if pipController.isPictureInPicturePossible {
            pipController.startPictureInPicture()
            return
        }

        guard startRetries < Self.maxStartRetries else {
            report("""
            系统当前不允许启动画中画。可能的原因：
            · 不是真机（模拟器不支持 PiP）
            · 正在录屏或通话，占用了 PiP
            · 在 LiveContainer 里 —— 容器的宿主 App 需要允许 PiP
            """)
            return
        }
        retryStart()
    }

    private func retryStart() {
        startRetries += 1
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.attemptStart()
        }
    }

    func stop() {
        cancelPendingStart()
        isStarting = false
        updateTask?.cancel()
        updateTask = nil
        pipController?.stopPictureInPicture()
        isActive = false
        onActiveChanged?(false)
        contentProvider = nil
        deactivateAudioSession()
    }

    /// 统一的失败上报：既记状态，也推给界面。
    private func report(_ message: String) {
        lastError = message
        isStarting = false
        onError?(message)
    }

    /// 停掉重试链路。用户主动 stop 之后不该再有任何后台重试把 PiP 拉起来。
    private func cancelPendingStart() {
        startRetries = Self.maxStartRetries + 1
    }

    /// 只往 display layer 画一帧，**不启动 PiP**。
    ///
    /// 给界面上的预览区用：既让用户看见"悬浮窗里会显示什么"，
    /// 也顺带保证 layer 里始终有内容（空 layer 启动 PiP 会闪白）。
    func primeDisplay(with content: PiPContent) {
        render(content: content)
    }

    /// 立刻用最新内容刷新一帧（不需要等下一个 1 秒节拍）。
    func refreshNow() {
        guard let contentProvider, isActive else { return }
        render(content: contentProvider())
    }

    // MARK: - 搭建

    private func setUpController() -> Bool {
        // displayLayer 必须有非零尺寸，否则 PiP 会拒绝。
        displayLayer.frame = CGRect(origin: .zero, size: Self.renderSize)
        displayLayer.videoGravity = .resizeAspect

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // 允许用户在 PiP 窗口上看到播放/暂停按钮（我们把它当"暂停计时"用）。
        controller.canStartPictureInPictureAutomaticallyFromInline = false

        pipController = controller
        return true
    }

    // MARK: - 渲染管线

    private func startUpdateLoop() {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            // 每秒一帧：倒计时是分钟级，但每秒走一下看起来才是"活的"。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if let provider = self.contentProvider {
                    self.render(content: provider())
                }
            }
        }
    }

    private func render(content: PiPContent) {
        guard let image = makeImage(content: content),
              let buffer = makePixelBuffer(from: image),
              let sample = makeSampleBuffer(from: buffer) else { return }

        // status == .failed 之后 displayLayer 会拒绝新帧，必须先 flush。
        if displayLayer.status == .failed {
            displayLayer.flush()
            renderFailureCount += 1
        }
        displayLayer.enqueue(sample)

        // 连续失败说明渲染管线有问题（尺寸、格式、IOSurface）。
        // 一次都不报的话，用户看到的就只是"黑屏"。
        if displayLayer.status == .failed, renderFailureCount == 5 {
            report("画中画的画面渲染失败：\(displayLayer.error?.localizedDescription ?? "未知原因")")
        }
    }

    /// SwiftUI 视图 → UIImage。
    private func makeImage(content: PiPContent) -> UIImage? {
        let renderer = ImageRenderer(content: PiPContentView(content: content))
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(Self.renderSize)
        return renderer.uiImage
    }

    /// UIImage → CVPixelBuffer（32BGRA）。
    private func makePixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage else { return nil }

        let width = Int(Self.renderSize.width)
        let height = Int(Self.renderSize.height)

        // ⚠️ IOSurface 这一项是必需的，不是优化。
        //    AVSampleBufferDisplayLayer 只接受 IOSurface 支撑的像素缓冲；
        //    少了这个键，enqueue 不会报错但画面永远是黑的 —— 又一个"静默失败"。
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            // 32BGRA 要用 little-endian + premultipliedFirst，顺序写反颜色会变。
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    /// CVPixelBuffer → CMSampleBuffer。
    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard let formatDescription else { return nil }

        frameIndex += 1
        // PTS 必须递增：一直用同一个 PTS，display layer 可能认为"没有新帧"而不刷新。
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: frameIndex, timescale: 30),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sampleBuffer else { return nil }

        // displayLayer 默认会把帧"攒着"按 PTS 播出。我们的 PTS 是按帧号编的，
        // 跟真实时间没有关系，不标 DisplayImmediately 的话画面会滞后甚至不刷新。
        CMSetAttachment(
            sampleBuffer,
            key: kCMSampleAttachmentKey_DisplayImmediately,
            value: kCFBooleanTrue,
            attachmentMode: kCMAttachmentMode_ShouldPropagate
        )
        return sampleBuffer
    }

    // MARK: - 音频会话

    /// PiP 要长期存活需要一个活跃的音频会话。
    ///
    /// ⚠️ 这一段是本文件里**最没把握**的地方：我们其实不播任何声音，
    /// 但 `AVPictureInPictureController` 依赖 `UIBackgroundModes: audio`
    /// 把 App 保活在后台。真机上如果 PiP 一进后台就消失，八成是这里要改
    /// （常见做法是循环播一段静音音频，但那是为了绕过系统策略的 hack，
    ///   我不想在没实测的情况下先写进去）。
    private func activateAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        } catch {
            // 起不来不算致命：前台时 PiP 照常工作，只是切后台可能保不住。
            lastError = "音频会话未能激活：\(error.localizedDescription)"
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension WetnessPiPController: AVPictureInPictureControllerDelegate {

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = true
            self.isStarting = false
            self.lastError = nil
            self.onActiveChanged?(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            self.isActive = false
            self.isStarting = false
            self.updateTask?.cancel()
            self.updateTask = nil
            self.deactivateAudioSession()
            self.onActiveChanged?(false)
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            self.isActive = false
            self.onActiveChanged?(false)
            self.report("画中画启动失败：\(error.localizedDescription)")
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

/// 这个协议是强制的（非 optional 的方法都要实现）。
/// 我们的内容是"实时数字"而不是视频，所以一律按**直播流**处理：
/// 时间范围取无限大、永远处于播放状态、跳过操作直接回调完成。
extension WetnessPiPController: AVPictureInPictureSampleBufferPlaybackDelegate {

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        // 用户点了 PiP 窗口上的播放/暂停。我们的倒计时按真实时间走，
        // 不随这个按钮停 —— 所以这里只是立刻重画一帧，不改状态。
        Task { @MainActor in self.refreshNow() }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController
    ) -> CMTimeRange {
        // duration = +∞ 表示直播内容。这样 PiP 不会显示进度条与"跳过 15 秒"。
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController
    ) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        // 系统改了 PiP 窗口大小。我们的内容是按固定尺寸渲染的，
        // 交给 videoGravity 去缩放即可，这里不需要重新适配。
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        // 必须调用，否则播放 UI 会永久卡在"跳转中"。
        completionHandler()
    }
}
