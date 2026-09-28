//
//  LabelOCRService.swift
//  ArtAssist — 美术生的工具箱
//
//  用 Vision 读颜料包装上印的字（主要是**中文颜色名**）。
//
//  ── 为什么必须走 OCR ─────────────────────────────────────────
//  真实反馈：「颜料本身不同颜色的条形码都是一样的，不是每个颜色一个条形码」。
//
//  这不是 App 能修的 —— 条码里根本没有颜色信息。管子上真正唯一的、
//  每支都不一样的，是**印上去的字**：群青、钛白、深红。
//  所以要建库，只能认字。
//
//  ── 关于隐私与权限 ────────────────────────────────────────────
//  Vision 的识别**完全在本机**完成，不联网、不上传，也不需要任何权限
//  （不像相机，OCR 没有额外的授权弹窗）。
//  这对 LiveContainer 环境也友好：相机权限可能拿不到，但手输 + 已有的
//  相册照片仍然能走 OCR。
//
//  ── 关于性能 ─────────────────────────────────────────────────
//  中文 OCR 不便宜（`.accurate` + 语言纠正，一帧几百毫秒）。
//  所以：
//    · 帧率由调用方限流（约 1 秒一帧，见 QRScannerViewController.frameInterval）
//    · 这里再加一道 isBusy 闸，上一帧没认完就丢掉新帧，不排队
//  宁可慢一点、稳一点，也不要堆一队任务把界面拖卡。
//

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Observation
import Vision

@MainActor
@Observable
final class LabelOCRService {

    /// 正在识别。界面上用来自责是否该显示"识别中"。
    private(set) var isBusy = false
    /// 上一次识别的行数，用于判断"有没有在读到东西"。
    private(set) var lastLineCount = 0
    /// 累计识别次数，便于排查"根本没跑起来"。
    private(set) var recognitionCount = 0
    /// 最后一次失败原因（正常情况下是 nil）。
    private(set) var lastError: String?

    /// 实际可用的识别语言。
    ///
    /// 不能盲目写死 `["zh-Hans", "en-US"]` —— 设备上不一定装了中文识别包，
    /// 传了不支持的语言 `VNRecognizeTextRequest` 会直接抛错，OCR 就整个不工作了。
    /// 所以先问系统，再挑。
    let languages: [String]

    private let queue = DispatchQueue(label: "com.artstock.ocr", qos: .userInitiated)

    /// 跨队列传 CoreVideo / CoreGraphics 对象的壳子。
    ///
    /// `CVPixelBuffer` 与 `CGImage` 都是 CF 类型，Swift 的并发检查会拒绝它们
    /// 进入 `@Sendable` 闭包。但这里跨队列**是安全的**：
    ///   · 存进闭包会 retain，CoreVideo 的引用计数保证读取期间不会被回收；
    ///   · 我们只读不写；
    ///   · 相机那边 `alwaysDiscardsLateVideoFrames = true`，而且帧率被限流到
    ///     约每秒一帧、OCR 侧还有 isBusy 闸，最多同时压着一两个缓冲。
    /// 所以显式标成 unchecked，而不是为了消警告去加一次无谓的内存拷贝。
    private struct UncheckedBuffer<Value>: @unchecked Sendable {
        let value: Value
    }

    init() {
        self.languages = Self.resolveLanguages()
    }

    private static func resolveLanguages() -> [String] {
        // ⚠️ 用**实例方法** supportedRecognitionLanguages()。
        //    类方法 supportedRecognitionLanguages(for:revision:) 在 iOS 15 就废弃了，
        //    而且它需要你手写 revision —— 实例方法会自动用你设的那个，不会对不上。
        let probe = VNRecognizeTextRequest()
        probe.recognitionLevel = .accurate
        probe.revision = VNRecognizeTextRequestRevision3
        let supported = (try? probe.supportedRecognitionLanguages()) ?? []

        let wanted = ["zh-Hans", "zh-Hant", "en-US"]
        let available = wanted.filter { supported.contains($0) }
        // 一个都没有就交回给系统自己决定（传空数组）。
        return available
    }

    /// 识别一帧画面。
    ///
    /// - Parameters:
    ///   - pixelBuffer: 相机帧或照片。
    ///   - orientation: 画面的真实朝向。方向搞错的话中文是一行都读不出来的。
    ///   - profile: 图像预处理档位。`.dotMatrix` 专门对付工业点阵喷码。
    ///   - zoom: 数码变焦倍数。喷码字很小，把它放大到占满画面再识别，
    ///     往往比调模型更管用 —— 限制识别率的是**像素密度**，不是模型。
    /// - Returns: 识别到的文本行。空数组表示这一帧没读到东西。
    /// - Parameters:
    ///   - roi: **归一化**的目标区域。用户在取景框上点一下文字的位置，
    ///     只识别那一小块。真照片上验证过：喷码常常不在画面正中
    ///     （人本能地把整包对进取景框），所以"裁中央再放大"这种做法
    ///     会把要识别的那行裁掉。让用户指一下最省事也最准。
    ///   - rotationDegrees: 额外旋转 0 / 90 / 270。
    ///     真照片上那行喷码是**竖排**的（批号沿袋子纵向印），
    ///     不转正的话再怎么预处理也读不出来。
    func recognize(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up,
        profile: TextImagePreprocessor.Profile = .none,
        zoom: Int = 1,
        roi: CGRect? = nil,
        rotationDegrees: Int = 0
    ) async -> [PaintLabelLine] {
        // 上一帧还没认完就直接丢掉这一帧 —— 不排队。
        guard !isBusy else { return [] }
        isBusy = true
        defer { isBusy = false }

        let languages = self.languages
        let boxed = UncheckedBuffer(value: pixelBuffer)
        let lines = await withCheckedContinuation { (continuation: CheckedContinuation<[PaintLabelLine], Never>) in
            queue.async {
                let result = Self.performRecognition(
                    pixelBuffer: boxed.value,
                    orientation: orientation,
                    languages: languages,
                    profile: profile,
                    zoom: zoom,
                    roi: roi,
                    rotationDegrees: rotationDegrees
                )
                continuation.resume(returning: result)
            }
        }

        recognitionCount += 1
        lastLineCount = lines.count
        return lines
    }

    /// 先判断这画面像不像点阵喷码，再选预处理档位。
    ///
    /// 让用户每次自己去选"普通/喷码"是不现实的 —— 他不知道区别。
    /// 判据见 `TextImagePreprocessor.dotMatrixLikelihood`。
    /// 判错的代价只是用错预处理，所以阈值取保守一点。
    func suggestProfile(for pixelBuffer: CVPixelBuffer) -> TextImagePreprocessor.Profile {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return .enhance }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // 判断用的图不用大，先降到 1/3 省时间
        let gray = TextImagePreprocessor.grayscale(
            bgra: base.assumingMemoryBound(to: UInt8.self),
            bytesPerRow: bytesPerRow, width: width, height: height
        )
        let small = TextImagePreprocessor.crop(
            gray, normalizedRect: CGRect(x: 0.15, y: 0.35, width: 0.7, height: 0.3)
        )
        let score = TextImagePreprocessor.dotMatrixLikelihood(small)
        return score > 0.55 ? .dotMatrix : .enhance
    }

    /// 识别一张 CGImage（手输页、相册、截图都能用）。
    ///
    /// - Parameter vocabulary: **期望出现的词**。传进来会作为 Vision 的
    ///   `customWords` —— 这些词的召回率和拼写准确度都会明显变好。
    ///   网页截图那条路会把"用户库里已有的耗材名/颜色名/色号"传进来，
    ///   于是"樱花橡皮""温莎牛顿白"这种词不容易被认错。
    /// - Parameter minimumTextHeight: 最小文字高度（占图高比例）。
    ///   默认 0.012 是给标签/包装上那种大字用的；**网页截图里的小字更小**，
    ///   用默认值会把整行直接丢掉，所以那条路会传更小的值。
    func recognize(
        cgImage: CGImage,
        orientation: CGImagePropertyOrientation = .up,
        vocabulary: [String] = [],
        minimumTextHeight: Double? = nil
    ) async -> [PaintLabelLine] {
        guard !isBusy else { return [] }
        isBusy = true
        defer { isBusy = false }

        let languages = self.languages
        let boxed = UncheckedBuffer(value: cgImage)
        let lines = await withCheckedContinuation { (continuation: CheckedContinuation<[PaintLabelLine], Never>) in
            queue.async {
                let request = Self.makeRequest(
                    languages: languages,
                    vocabulary: vocabulary,
                    minimumTextHeight: minimumTextHeight
                )
                let handler = VNImageRequestHandler(cgImage: boxed.value, orientation: orientation, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: Self.collect(from: request))
            }
        }

        recognitionCount += 1
        lastLineCount = lines.count
        return lines
    }

    // MARK: - 实际干活（在 queue 上）

    private nonisolated static func performRecognition(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        languages: [String],
        profile: TextImagePreprocessor.Profile = .none,
        zoom: Int = 1,
        roi: CGRect? = nil,
        rotationDegrees: Int = 0
    ) -> [PaintLabelLine] {
        // 需要预处理、数码变焦、或者用户指了区域时，先把帧过一遍流水线，
        // 再把它当一张普通图片交给 Vision。
        if profile != .none || zoom > 1 || roi != nil {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return [] }

            guard let processed = TextImagePreprocessor.process(
                bgra: base.assumingMemoryBound(to: UInt8.self),
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer),
                profile: profile,
                zoom: zoom,
                roi: roi
            ) else { return [] }

            guard let image = makeCGImage(
                bgra: processed.pixels,
                width: processed.width,
                height: processed.height
            ) else { return [] }

            let request = makeRequest(languages: languages, forCodes: profile == .dotMatrix)
            // 旋转交给 Vision 的 orientation，而不是自己去转像素 ——
            // CGImagePropertyOrientation 的 8 种取值语义是系统定义的，
            // 自己写旋转矩阵很容易把 90 和 270 搞反（实验室里就这么错过一次）。
            let handler = VNImageRequestHandler(
                cgImage: image,
                orientation: Self.visionOrientation(forDegrees: rotationDegrees),
                options: [:]
            )
            do {
                try handler.perform([request])
            } catch {
                return []
            }
            return collect(from: request)
        }

        let request = makeRequest(languages: languages)
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            // 相机缓冲本来就已经被 RotationCoordinator 转正了；
            // 用户选的额外旋转叠加上去。
            orientation: Self.combine(orientation, withDegrees: rotationDegrees),
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        return collect(from: request)
    }

    /// 角度 → `CGImagePropertyOrientation`。
    ///
    /// 只支持 0 / 90 / 270：这三个是喷码实际会出现的姿态（竖排、横排）。
    /// 180 没有实际意义 —— 谁会倒着拿袋子。
    private nonisolated static func visionOrientation(
        forDegrees degrees: Int
    ) -> CGImagePropertyOrientation {
        switch ((degrees % 360) + 360) % 360 {
        case 90: return .right
        case 180: return .down
        case 270: return .left
        default: return .up
        }
    }

    /// 把"相机已经转正的方向"和"用户额外选的旋转"合起来。
    ///
    /// 两者都是 90° 的整数倍，所以这里做的是角度相加。
    /// 相机路径上 `orientation` 通常已经是 `.up`（RotationCoordinator 转过像素了），
    /// 那就等于直接用用户的旋转。
    private nonisolated static func combine(
        _ base: CGImagePropertyOrientation,
        withDegrees degrees: Int
    ) -> CGImagePropertyOrientation {
        guard degrees % 360 != 0 else { return base }
        // 相机路径上像素已经被转正，base 基本总是 .up；真有别的值时
        // 以用户选择为准更符合直觉。
        return visionOrientation(forDegrees: degrees)
    }

    /// 把一堆 BGRA 字节包成 CGImage，好交给 Vision。
    private nonisolated static func makeCGImage(
        bgra: [UInt8],
        width: Int,
        height: Int
    ) -> CGImage? {
        guard width > 0, height > 0, bgra.count >= width * height * 4 else { return nil }
        let bytesPerRow = width * 4
        guard let provider = CGDataProvider(data: Data(bgra) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            // 我们的缓冲是 B、G、R、A，也就是 little-endian 下的 premultipliedFirst
            bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private nonisolated static func makeRequest(
        languages: [String],
        forCodes: Bool = false,
        vocabulary: [String] = [],
        minimumTextHeight: Double? = nil
    ) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        // .accurate 比 .fast 对中文好非常多，值得多花那点时间。
        request.recognitionLevel = .accurate
        request.revision = VNRecognizeTextRequestRevision3
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }

        if forCodes {
            // 喷码是**编号**不是词。语言纠正会把 `20250G12A3` 这种
            // "纠正"成一个看起来像词的错东西 —— 对编号是纯粹的伤害。
            request.usesLanguageCorrection = false
            // 喷码字小，把最小文字高度放宽；太大就直接被丢掉了。
            request.minimumTextHeight = 0.004
            // 告诉它我们期望出现哪些词，能显著提升这些词的召回。
            request.customWords = Self.domainWords
        } else {
            // 印刷体：语言纠正能救回不少形近字的错读（赭/诸、群/群）。
            request.usesLanguageCorrection = true
            // minimumTextHeight 是 Float，调用方传 Double 更方便
            request.minimumTextHeight = Float(minimumTextHeight ?? 0.012)
        }
        // 自定义词表：把"期望出现的词"告诉 Vision，这些词的召回与拼写会变准。
        // 喷码那条路用固定的领域词；网页截图那条路用**用户自己库里的东西**。
        if !vocabulary.isEmpty {
            request.customWords = (request.customWords ?? []) + vocabulary
        }
        return request
    }

    /// 这个领域里会出现的词。喂给 Vision 能提升召回。
    ///
    /// 42 个色名 + 常见品牌。不是白名单，只是"优先猜这些"。
    private nonisolated static var domainWords: [String] {
        PresetColors.standard42.map(\.name) + [
            "马利", "米娅", "温莎牛顿", "樱花", "辉柏嘉", "美邦", "青竹",
            "水粉", "丙烯", "国画", "颜料", "色号", "批号"
        ]
    }

    private nonisolated static func collect(from request: VNRecognizeTextRequest) -> [PaintLabelLine] {
        let observations = request.results ?? []
        var lines: [PaintLabelLine] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append(PaintLabelLine(text: text, confidence: Double(candidate.confidence)))
        }
        return lines
    }
}
