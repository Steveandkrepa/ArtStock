//
//  paint-ocr-lab.swift
//  ArtAssist — 美术生的工具箱
//
//  **离线 OCR 实验室。** 在 Mac 上跑，不在 App 里跑。
//
//  ── 它解决什么问题 ───────────────────────────────────────────
//  「喷码识别不准」这件事必须拿**真实的包装照片**来定量，否则只能猜。
//  而 App 里没法做对照实验：你只能看到一个结果，看不到"如果不预处理会怎样"。
//
//  这个工具把同一张图喂给多条管线，把结果并排列出来：
//
//      原图            Vision 直接读
//      增强档位       放大 2 倍 + 对比度均衡
//      喷码档位       放大 + 均衡 + 局部自适应二值化 + 闭运算
//      数码变焦 2×/3× 只取画面中央再识别
//
//  于是"预处理到底有没有用、哪一档最好"是可以**看出来**的，
//  而不是靠感觉。参数要调也在这里调，调完再同步进 App。
//
//  ── 为什么能在这台机器上跑 ───────────────────────────────────
//  Vision 框架 macOS 上就有（`VNRecognizeTextRequest`），
//  预处理代码是纯 CoreGraphics + Foundation（不依赖 UIKit），
//  所以整条链能原样编译到 macOS。这在 iOS 项目里是少见的便利 ——
//  充分利用它，把"只能真机试"的部分压到最小。
//
//  用法：
//      swiftc -O -o /tmp/ocrlab scripts/paint-ocr-lab.swift \
//          ArtStock/Services/TextImagePreprocessor.swift \
//          ArtStock/Models/PresetColors.swift
//      /tmp/ocrlab 照片.jpg [期望的文字]
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

// MARK: - 参数

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("""
    用法: ocrlab <图片路径> [期望读到的文字]

      图片路径   包装上那行喷码的照片（原图，不要裁、不要压缩）
      期望文字   可选。填了就能算出"这一档认对没有"

    例:  ocrlab tube.jpg 群青
         ocrlab tube.jpg 20250612A3
    """)
    exit(2)
}

let imagePath = arguments[1]
let expectation = arguments.count >= 3 && !arguments[2].hasPrefix("--")
    ? arguments[2] : nil
let hasExpectation = expectation != nil

/// `--roi x,y,w,h`（归一化）只处理这块区域 —— 用来把喷码单独抠出来看。
var roi: CGRect? = nil
/// `--save-roi 路径.png` 把 ROI 原样导出，方便肉眼看清楚。
var roiOutputPath: String? = nil
/// `--rotate 90|180|270` 额外旋转（EXIF 之外再转）。
var extraRotation = 0
/// `--engine fast|accurate|both`（默认 both）。
///
/// 为什么需要它：本机实测 `.accurate`（中文引擎）报
/// `TextRecognition.CRImageReaderError code=9` —— 连干净的 PNG 都读不了，
/// 是**环境缺模型资源**，不是代码问题。而 `.fast` 档正常。
/// 数字+字母的喷码批号用 `.fast` 就够（而且它本来就不需要语言模型）。
var engines: [EngineChoice] = [.fast, .accurate]

enum EngineChoice: String {
    case fast, accurate
    var level: VNRequestTextRecognitionLevel { self == .fast ? .fast : .accurate }
    var displayName: String { self == .fast ? "fast" : "accurate" }
}

var index = 2
while index < arguments.count {
    switch arguments[index] {
    case "--roi":
        index += 1
        if index < arguments.count {
            let parts = arguments[index].split(separator: ",").compactMap { Double($0) }
            if parts.count == 4 {
                roi = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
            }
        }
    case "--save-roi":
        index += 1
        if index < arguments.count { roiOutputPath = arguments[index] }
    case "--rotate":
        index += 1
        if index < arguments.count { extraRotation = Int(arguments[index]) ?? 0 }
    case "--engine":
        index += 1
        if index < arguments.count {
            switch arguments[index] {
            case "fast": engines = [.fast]
            case "accurate": engines = [.accurate]
            default: engines = [.fast, .accurate]
            }
        }
    default:
        break
    }
    index += 1
}

// MARK: - 图片载入

/// 一张已经规整好的 BGRA 图。
///
/// 用结构体而不是元组：裁剪和旋转会改变宽高，元组一旦长度或顺序对不上
/// 就是编译期说不清的报错（先写过一版元组，就是这么错的）。
/// 结构体还能把 `bytesPerRow` 变成派生值，永远跟宽度一致。
struct LoadedImage {
    var pixels: [UInt8]
    var width: Int
    var height: Int
    var bytesPerRow: Int { width * 4 }
}

/// 把图片文件读成 BGRA 缓冲（行优先，第 0 行 = 画面顶部）。
///
/// ⚠️ 行序**不能凭直觉写**。
///    我一开始以为"CGContext 原点在左下，所以要翻转"，于是加了一次
///    `translate + scale(1,-1)` —— 结果正好反了（自检显示第 0 行变成了图的下半）。
///    实测结论：`CGContext.draw(image, in:)` 在这样一个位图上下文里
///    **本来就是第 0 行 = 画面顶部**，不需要翻转。
///
///    这件事值得留个记录：方向搞反了整幅图上下颠倒，OCR 一个字都读不出来，
///    而输出看起来只像"模型不行"。`--selftest` 就是专门钉这一点的。
func loadBGRA(path: String) -> LoadedImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

    // ⚠️ **必须处理 EXIF 方向。**
    //    iPhone 拍的照片常常是"横着存、竖着显"（orientation = 6），
    //    而 CGImageSourceCreateImageAtIndex 给的是**未旋转**的像素。
    //    不处理的话喂给 Vision 的就是一张躺着的图 —— 8 条管线全部读不出东西，
    //    而输出看起来只像"识别不了"。这正是真照片上第一次跑出来的结果。
    //
    //    用 CoreImage 的 oriented(forExifOrientation:) 而不是手写变换矩阵：
    //    8 种方向的矩阵很容易记错，而这个是系统按 EXIF 定义实现的。
    let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        .flatMap { $0[kCGImagePropertyOrientation] as? UInt32 } ?? 1
    let oriented = CIImage(cgImage: image)
        .oriented(forExifOrientation: Int32(orientation))

    // 用 createCGImage 拿到"已经转正"的位图，再走那条已经自检验证过行序的绘制路径。
    // （`CIContext.render(_:to:bounds:colorSpace:)` 收 CGContext 的重载在 macOS 上
    //   不存在，只有收 CVPixelBuffer 的那个。）
    guard let orientedImage = CIContext(options: [.useSoftwareRenderer: false])
        .createCGImage(oriented, from: oriented.extent) else { return nil }

    let width = orientedImage.width
    let height = orientedImage.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

    guard let context = CGContext(
        data: &pixels, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }

    context.draw(orientedImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    return LoadedImage(pixels: pixels, width: width, height: height)
}

// MARK: - 自检

if imagePath == "--selftest" {
    runSelfTest()
    exit(0)
}

let rawLoaded = loadBGRA(path: imagePath)
guard let rawLoaded else {
    print("❌ 读不出这张图：\(imagePath)")
    exit(1)
}

/// 把 BGRA 缓冲按 90° 的整数倍旋转。喷码经常是竖排的，抠出来之后要转正。
func rotateBGRA(_ image: LoadedImage, degrees: Int) -> LoadedImage {
    let pixels = image.pixels
    let width = image.width
    let height = image.height
    let normalized = ((degrees % 360) + 360) % 360
    guard normalized != 0 else { return image }
    let swap = normalized == 90 || normalized == 270
    let newWidth = swap ? height : width
    let newHeight = swap ? width : height
    var out = [UInt8](repeating: 0, count: newWidth * newHeight * 4)

    for y in 0..<height {
        for x in 0..<width {
            let source = (y * width + x) * 4
            let target: Int
            switch normalized {
            case 90:  target = ((x) * newWidth + (height - 1 - y)) * 4
            case 180: target = ((height - 1 - y) * newWidth + (width - 1 - x)) * 4
            default:  target = ((width - 1 - x) * newWidth + y) * 4
            }
            for channel in 0..<4 { out[target + channel] = pixels[source + channel] }
        }
    }
    return LoadedImage(pixels: out, width: newWidth, height: newHeight)
}

/// 按归一化矩形裁剪。
func cropBGRA(_ image: LoadedImage, rect: CGRect) -> LoadedImage {
    let pixels = image.pixels
    let width = image.width
    let height = image.height
    let x0 = max(0, Int((rect.minX * Double(width)).rounded(.down)))
    let y0 = max(0, Int((rect.minY * Double(height)).rounded(.down)))
    let x1 = min(width, Int((rect.maxX * Double(width)).rounded(.up)))
    let y1 = min(height, Int((rect.maxY * Double(height)).rounded(.up)))
    guard x1 > x0, y1 > y0 else { return image }

    let newWidth = x1 - x0
    let newHeight = y1 - y0
    var out = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
    for y in 0..<newHeight {
        for x in 0..<newWidth {
            let source = ((y0 + y) * width + (x0 + x)) * 4
            let target = (y * newWidth + x) * 4
            for channel in 0..<4 { out[target + channel] = pixels[source + channel] }
        }
    }
    return LoadedImage(pixels: out, width: newWidth, height: newHeight)
}

var loaded = rawLoaded
if let roi {
    loaded = cropBGRA(loaded, rect: roi)
}
if extraRotation != 0 {
    loaded = rotateBGRA(loaded, degrees: extraRotation)
}

print("════════════════════════════════════════════════════════")
print("图片  \(imagePath)")
print("原始  \(rawLoaded.width) × \(rawLoaded.height)")
if roi != nil || extraRotation != 0 {
    print("处理后 \(loaded.width) × \(loaded.height)"
          + (roi.map { "   ROI \($0)" } ?? "")
          + (extraRotation != 0 ? "   旋转 \(extraRotation)°" : ""))
}
if let expectation {
    print("期望  「\(expectation)」")
}
print("════════════════════════════════════════════════════════")

// 导出 ROI 原图，方便肉眼确认裁对了地方
if let roiOutputPath, let image = makeCGImage(bgra: loaded.pixels,
                                              width: loaded.width, height: loaded.height) {
    if let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: roiOutputPath) as CFURL, "public.png" as CFString, 1, nil
    ) {
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
        print("已导出 ROI → \(roiOutputPath)")
        print("")
    }
}

// MARK: - Vision

/// 上一次识别的错误。**不能吞掉** ——
///
/// 一开始这里写成 `catch { return [] }`，于是"语言包不支持导致 perform 抛错"
/// 看起来跟"这张图没有文字"完全一样，白查了半天。
/// 这种静默失败是排查成本最高的一类问题。
var lastRecognitionError: String?

/// 系统支持哪些识别语言（本机查一次）。
var supportedLanguages: [String] = {
    let probe = VNRecognizeTextRequest()
    probe.recognitionLevel = .accurate
    return (try? probe.supportedRecognitionLanguages()) ?? []
}()

/// 在一张 CGImage 上跑一次文字识别。
func recognize(
    _ image: CGImage, codeMode: Bool, engine: EngineChoice
) -> [(text: String, confidence: Double)] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = engine.level
    request.revision = VNRecognizeTextRequestRevision3
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    if codeMode {
        // 编号不是词，语言纠正会把它"纠正"坏
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.004
    } else {
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.008
    }

    let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
    do {
        try handler.perform([request])
    } catch {
        lastRecognitionError = "\(error)"
        return []
    }
    guard let results = request.results else { return [] }
    return results.compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (text, Double(candidate.confidence))
    }
}

/// BGRA 字节 → CGImage。
func makeCGImage(bgra: [UInt8], width: Int, height: Int) -> CGImage? {
    guard width > 0, height > 0, bgra.count >= width * height * 4 else { return nil }
    guard let provider = CGDataProvider(data: Data(bgra) as CFData) else { return nil }
    return CGImage(
        width: width, height: height,
        bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )
}

// MARK: - 跑各条管线

struct Attempt {
    var label: String
    var lines: [(text: String, confidence: Double)]
    var hit: Bool
    var best: String { lines.map(\.text).joined(separator: " / ") }
    var topConfidence: Double { lines.map(\.confidence).max() ?? 0 }
}

var attempts: [Attempt] = []

func run(_ label: String, profile: TextImagePreprocessor.Profile, zoom: Int, codeMode: Bool) {
    for engine in engines { run(label: label, profile: profile, zoom: zoom,
                               codeMode: codeMode, engine: engine) }
}

func run(label: String, profile: TextImagePreprocessor.Profile, zoom: Int,
         codeMode: Bool, engine: EngineChoice) {
    var bgra: [UInt8]
    var width: Int
    var height: Int

    if profile == .none && zoom == 1 {
        bgra = loaded.pixels
        width = loaded.width
        height = loaded.height
    } else {
        guard let processed = loaded.pixels.withUnsafeBufferPointer({ pointer in
            TextImagePreprocessor.process(
                bgra: pointer.baseAddress!,
                bytesPerRow: loaded.bytesPerRow,
                width: loaded.width,
                height: loaded.height,
                profile: profile,
                zoom: zoom
            )
        }) else {
            attempts.append(Attempt(label: label, lines: [], hit: false))
            return
        }
        bgra = processed.pixels
        width = processed.width
        height = processed.height
    }

    guard let image = makeCGImage(bgra: bgra, width: width, height: height) else {
        attempts.append(Attempt(label: label, lines: [], hit: false))
        return
    }

    let lines = recognize(image, codeMode: codeMode, engine: engine)
    let hit: Bool
    if let expectation {
        hit = lines.contains { $0.text.contains(expectation) }
    } else {
        hit = !lines.isEmpty
    }
    let sizeNote = "\(width)×\(height)"
    attempts.append(Attempt(
        label: "\(label) · \(engine.displayName) [\(sizeNote)]",
        lines: lines, hit: hit
    ))
}

// 先把系统能力打出来 —— 语言包缺了的话，后面所有结果都没有意义
print("")
print("系统支持的识别语言：\(supportedLanguages.isEmpty ? "（查询失败）" : supportedLanguages.joined(separator: "、"))")
if !supportedLanguages.isEmpty, !supportedLanguages.contains("zh-Hans") {
    print("⚠️ 本机没有简体中文识别包 —— 中文结果会全部是空的，这不是图的问题")
}
// 超大图的提示
let megapixels = Double(loaded.width * loaded.height) / 1_000_000
if megapixels > 20 {
    print(String(format: "⚠️ 这张图 %.0f 百万像素，放大 2 倍后是 %.0f 百万像素 —— 可能超出 Vision 的舒适区", megapixels, megapixels * 4))
}

// 原图基准
run("① 原图", profile: .none, zoom: 1, codeMode: false)
// 增强档位（印刷体）
run("② 增强 2×", profile: .enhance, zoom: 1, codeMode: false)
// 喷码档位（点阵）
run("③ 喷码 2×", profile: .dotMatrix, zoom: 1, codeMode: false)
// 数码变焦（先裁再放大）
run("④ 变焦 2× + 喷码", profile: .dotMatrix, zoom: 2, codeMode: false)
run("⑤ 变焦 3× + 喷码", profile: .dotMatrix, zoom: 3, codeMode: false)
// 编号模式（关语言纠正）
run("⑥ 原图 · 编号模式", profile: .none, zoom: 1, codeMode: true)
run("⑦ 喷码 2× · 编号模式", profile: .dotMatrix, zoom: 1, codeMode: true)
run("⑧ 变焦 2× · 编号模式", profile: .dotMatrix, zoom: 2, codeMode: true)

// MARK: - 输出

/// 左侧对齐补空格。
///
/// ⚠️ 不能用 `String(format: "%-26s", someNSString)` ——
///    `%s` 要的是 C 字符串（char*），传 NSString 对象进去是未定义行为，
///    实测**直接段错误**。中文还得按显示宽度算，所以干脆自己补。
func pad(_ text: String, to width: Int) -> String {
    // 中日韩字符按两格宽算，否则表格会歪
    let displayWidth = text.reduce(0) { partial, character in
        let isWide = character.unicodeScalars.contains { scalar in
            (0x1100...0x115F).contains(scalar.value)
                || (0x2E80...0xA4CF).contains(scalar.value)
                || (0xAC00...0xD7A3).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
                || (0xFE30...0xFE6F).contains(scalar.value)
                || (0xFF00...0xFF60).contains(scalar.value)
                || (0xFFE0...0xFFE6).contains(scalar.value)
        }
        return partial + (isWide ? 2 : 1)
    }
    if displayWidth >= width { return text }
    return text + String(repeating: " ", count: width - displayWidth)
}

print("")
var header = pad("管线", to: 28)
if hasExpectation { header += pad("命中", to: 6) }
header += pad("置信度", to: 9) + "读到的内容"
print(header)
print(String(repeating: "─", count: 84))

var hitCount = 0
for attempt in attempts {
    if attempt.hit { hitCount += 1 }
    let body = attempt.lines.isEmpty
        ? "（没读到东西）"
        : attempt.lines.map { "\($0.text)(\(Int($0.confidence * 100))%)" }.joined(separator: " | ")
    var row = pad(attempt.label, to: 28)
    if hasExpectation { row += pad(attempt.hit ? "✅" : "—", to: 6) }
    row += pad(String(format: "%.0f%%", attempt.topConfidence * 100), to: 9) + body
    print(row)
}

if let lastRecognitionError {
    print("")
    print("⚠️ 识别时报错：\(lastRecognitionError)")
}

// MARK: - 点阵可能性

print("")
let grayFull = loaded.pixels.withUnsafeBufferPointer { pointer in
    TextImagePreprocessor.grayscale(
        bgra: pointer.baseAddress!, bytesPerRow: loaded.bytesPerRow,
        width: loaded.width, height: loaded.height
    )
}
let center = TextImagePreprocessor.crop(
    grayFull, normalizedRect: CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.4)
)
let score = TextImagePreprocessor.dotMatrixLikelihood(center)
print(String(format: "点阵可能性  %.2f   ", score)
      + (score > 0.55 ? "→ 像点阵喷码，App 会自动切到「喷码」档位"
                      : "→ 像印刷体，App 会用「增强」档位"))
// 中心区域的平均亮度与对比度，能看出是不是过曝/欠曝
let values = center.bytes.map(Int.init)
if !values.isEmpty {
    let mean = Double(values.reduce(0, +)) / Double(values.count)
    let sorted = values.sorted()
    let p5 = Double(sorted[sorted.count / 20])
    let p95 = Double(sorted[sorted.count - 1 - sorted.count / 20])
    print(String(format: "中心区域    平均灰度 %.0f   5%%–95%% 跨度 %.0f   ", mean, p95 - p5)
          + (p95 - p5 < 60 ? "← 对比度很低，喷码容易糊"
                           : (mean > 200 ? "← 偏亮，可能过曝" : "← 看起来正常")))
}

print("")
if hasExpectation {
    print("命中 \(hitCount) / \(attempts.count) 条管线")
    if hitCount == 0 {
        print("→ 所有管线都没读对。这条喷码用现有方法是**真的读不出来**，")
        print("  需要换模型，或者换拍摄方式（更近、更亮、更正对）。")
    } else if hitCount == attempts.count {
        print("→ 全都读对了。这条不是难点，可以换一条更难的试试。")
    } else {
        print("→ 有的管线读对了。看上面哪一档命中，那就是该用的参数。")
    }
}

// MARK: - 自检

/// 验证"图片载入后第 0 行是顶部"。
///
/// 这不是形式主义：搞反了整幅图上下颠倒，OCR 一个字都读不出来，
/// 而看输出只会以为"模型不行"。所以用一张上半白、下半黑的合成图钉死它。
func runSelfTest() {
    print("═══ 载入方向自检 ═══")

    // 造一张 40×40：上半白、下半黑
    let width = 40, height = 40
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        let value: UInt8 = y < height / 2 ? 255 : 0   // 第 0 行 = 顶部 = 白
        for x in 0..<width {
            let offset = (y * width + x) * 4
            pixels[offset] = value
            pixels[offset + 1] = value
            pixels[offset + 2] = value
            pixels[offset + 3] = 255
        }
    }
    guard let image = makeCGImage(bgra: pixels, width: width, height: height) else {
        print("❌ 造不出测试图"); return
    }

    // 写进临时文件，再走完整的"文件 → 缓冲"路径
    let tempPath = NSTemporaryDirectory() + "ocrlab-selftest.png"
    guard let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: tempPath) as CFURL, "public.png" as CFString, 1, nil
    ) else { print("❌ 建不了输出"); return }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { print("❌ 写不了文件"); return }

    guard let reloaded = loadBGRA(path: tempPath) else {
        print("❌ 回读失败"); return
    }

    let topValue = reloaded.pixels[0]
    let bottomValue = reloaded.pixels[(height - 1) * width * 4]
    print("  上半（第 0 行）灰度 = \(topValue)   期望 255")
    print("  下半（最后一行）灰度 = \(bottomValue)   期望 0")
    if topValue > 200 && bottomValue < 50 {
        print("  ✅ 方向正确：第 0 行是画面顶部")
    } else {
        print("  ❌ 方向反了 —— OCR 会一个字都读不出来，必须先修 loadBGRA 的翻转")
    }
    try? FileManager.default.removeItem(atPath: tempPath)
}
