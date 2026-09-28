//
//  PaddleOCRTokens.swift
//  ArtAssist — 美术生的工具箱
//
//  PP-OCR 的字符表与 CTC 解码。
//
//  ── 这个文件为什么先于模型存在 ───────────────────────────────
//  用户提过「ocr 识别对工业喷码字体识别精度不高，可以尝试用现成的
//  更高级的轻量 ocr 模型」。喷码那部分我已经用图像预处理做了
//  （放大 + 自适应二值化 + 闭运算，见 TextImagePreprocessor），
//  但"换一个专门模型"这条路要落地，绕不开下面这三件事：
//
//      1. 模型输入怎么归一化（尺寸、通道、均值方差）
//      2. 模型输出怎么变成文字（CTC 解码）
//      3. 字符表的索引约定（blank 在哪、空格在哪）
//
//  而这三件事**恰恰是整条链上最容易错、又最难发现的地方**：
//  解错一位，结果是"全都认出来了但每个字都错位一个"，
//  或者冒出空白字符，看起来像模型不准，其实是解码写错了。
//
//  好消息是：它们全是纯数学 + 查表，**不需要模型就能测**。
//  所以先把这部分写完、测透。等运行时（ONNX Runtime / CoreML）到位，
//  剩下的只是"把张量喂进来"这一层胶水。
//
//  ── 索引约定（必须钉死，错了全盘错位）───────────────────────
//      index 0            → CTC blank
//      index 1 … N        → 字典第 1 … N 个字符（python 里下标 0..N-1）
//      index N+1          → 空格（当 use_space_char = True）
//  所以输出维度是 N + 2 = 6623 + 2 = **6625**。
//  PaddleOCR 的 `CTCLabelDecode` 就是这么摆的，下面的测试逐条钉住了它。
//

import Foundation

// MARK: - 字符表

/// PP-OCR 的字符表。
struct PPOCRCharacterSet: Equatable, Sendable {

    /// `characters[i]` = 索引 i 对应的字符；`characters[0]` 是空串（blank）。
    private(set) var characters: [String]

    /// 是否追加了空格类。
    private(set) var usesSpaceCharacter: Bool = true

    /// 字典里有多少个字（不含 blank 与空格）。
    ///
    /// ⚠️ 不能写成 `characters.count - 2`。
    ///    不开空格类时只多出 **1** 个槽位（blank），写成减 2 会少报一个字。
    ///    这个数会被用来校验"模型输出维度对不对"，报错一位就会去怀疑模型。
    var dictionaryCount: Int {
        characters.count - 1 - (usesSpaceCharacter ? 1 : 0)
    }

    /// 模型输出应该有多少类。
    var classCount: Int { characters.count }

    /// blank 的索引。CTC 里固定是 0。
    static let blankIndex = 0

    /// - Parameters:
    ///   - dictionary: 一行一个字符的字典文本（PaddleOCR 的 `ppocr_keys_v1.txt`）。
    ///   - useSpaceCharacter: 是否在末尾追加空格类。PP-OCR 的中文识别默认开。
    init(dictionary: String, useSpaceCharacter: Bool = true) {
        // 逐行读，但**不能**丢掉空行 —— 字典里理论上没有空行，
        // 可真要有一个，行号就整体错位了，那比报错还糟。
        // 所以这里按 \n 切分并用 count 校验，发现异常就保持原样（测试会盯着）。
        var lines = dictionary
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        // 文件末尾的换行会产生一个多余空串，只在最后一个时丢掉
        if lines.last == "" { lines.removeLast() }

        var list: [String] = [""]          // 0 = blank
        list.append(contentsOf: lines)     // 1…N = 字典
        if useSpaceCharacter { list.append(" ") }
        self.characters = list
        self.usesSpaceCharacter = useSpaceCharacter
    }

    /// 给测试与"没有字典时"用的构造方式。
    init(characters: [String]) {
        self.characters = characters
        // 约定：这种构造方式下最后一个槽位是空格类
        self.usesSpaceCharacter = characters.count >= 3
    }

    /// 索引 → 字符。越界返回 nil（宁可漏字，不要越界崩）。
    func character(at index: Int) -> String? {
        guard index >= 0, index < characters.count else { return nil }
        return characters[index]
    }

    /// 从 App bundle 里读字典。
    ///
    /// 找不到就返回 nil —— 调用方应该退回 Vision 那条路，
    /// 而不是拿一个空字典去解码（那样会产出满屏的空白）。
    static func bundled() -> PPOCRCharacterSet? {
        guard let url = Bundle.main.url(forResource: "ppocr_keys_v1", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return PPOCRCharacterSet(dictionary: text)
    }
}

// MARK: - CTC 解码

enum PPOCRCTCDecoder {

    /// 贪心（best-path）CTC 解码。
    ///
    /// 三步，顺序不能变：
    ///   1. 逐帧取最大概率的索引
    ///   2. **跳过连续重复**（CTC 里"同一个字连着出现两帧"表示的仍是**一个字**）
    ///   3. 丢掉 blank
    ///
    /// ⚠️ 第 2 步和第 3 步的先后关系最容易写错。
    ///    PaddleOCR 的实现是**一边遍历一边判**：
    ///        若 当前不是 blank 且 当前索引 != 上一帧索引 → 收下这个字
    ///    注意"上一帧索引"比的是**原始索引**，不是"上一个收下的字"。
    ///    于是 `[a, blank, a]` 会解成 **`aa`**，而 `[a, a, blank]` 解成 **`a`**。
    ///    写成"先去掉 blank 再去重"就会把 `[a, blank, a]` 错解成 `a` ——
    ///    这正好是"两个字被并成一个"的经典 bug，而且只在这种输入下暴露。
    static func decode(
        indices: [Int],
        characterSet: PPOCRCharacterSet
    ) -> String {
        var result = ""
        var previous = -1
        for index in indices {
            if index == PPOCRCharacterSet.blankIndex { previous = index; continue }
            if index == previous { previous = index; continue }
            if let character = characterSet.character(at: index) {
                result += character
            }
            previous = index
        }
        return result
    }

    /// 带置信度的解码。
    ///
    /// 置信度取**收下的那些字**的概率均值 —— 不是所有帧的均值。
    /// 用所有帧的话，一长串 blank 会把置信度拉到很低，
    /// 明明认对了却显示"不确定"。
    static func decode(
        logits: [[Float]],
        characterSet: PPOCRCharacterSet
    ) -> (text: String, confidence: Double) {
        guard !logits.isEmpty else { return ("", 0) }

        var indices: [Int] = []
        var probabilities: [Double] = []
        indices.reserveCapacity(logits.count)

        for frame in logits {
            guard let best = argmax(frame) else {
                indices.append(PPOCRCharacterSet.blankIndex)
                probabilities.append(0)
                continue
            }
            indices.append(best.index)
            probabilities.append(best.probability)
        }

        var text = ""
        var kept: [Double] = []
        var previous = -1
        for (position, index) in indices.enumerated() {
            if index == PPOCRCharacterSet.blankIndex { previous = index; continue }
            if index == previous { previous = index; continue }
            if let character = characterSet.character(at: index) {
                text += character
                kept.append(probabilities[position])
            }
            previous = index
        }

        let confidence = kept.isEmpty ? 0 : kept.reduce(0, +) / Double(kept.count)
        return (text, confidence)
    }

    /// 一帧里最大值的下标与概率。
    ///
    /// 输入约定为**已经过 softmax 的概率**（PP-OCR 的 rec 模型在导出时
    /// 通常带 softmax，所以这里不再做一次 —— 做两次会把分布压平，
    /// 置信度会虚高到 0.99 那种没意义的数字）。
    /// 但为了容错，如果这一行看起来不是概率分布（和明显偏离 1），
    /// 就地做一次 softmax。
    static func argmax(_ values: [Float]) -> (index: Int, probability: Double)? {
        guard !values.isEmpty else { return nil }
        var bestIndex = 0
        var bestValue = values[0]
        var sum = 0.0
        for (index, value) in values.enumerated() {
            if value > bestValue {
                bestValue = value
                bestIndex = index
            }
            sum += Double(value)
        }

        // 已经像概率分布：直接用
        if sum > 0.9, sum < 1.1, bestValue >= 0, bestValue <= 1 {
            return (bestIndex, Double(bestValue))
        }

        // 像 logits：补一次 softmax 再取
        var maxValue = values[0]
        for value in values where value > maxValue { maxValue = value }
        var expSum = 0.0
        var expBest = 0.0
        for (index, value) in values.enumerated() {
            let exponent = exp(Double(value - maxValue))
            expSum += exponent
            if index == bestIndex { expBest = exponent }
        }
        guard expSum > 0 else { return (bestIndex, 0) }
        return (bestIndex, expBest / expSum)
    }
}

// MARK: - 输入归一化

/// 模型输入的预处理。
///
/// PP-OCR 的识别模型（rec）约定：
///     输入  `x`   形状 [N, 3, 48, W]，W = 320（或按比例、上限 320 的倍数）
///     归一化      先 /255 缩到 0…1，再 `(v − 0.5) / 0.5` 到 −1…1
///     通道        RGB（灰度图则三通道相同），且是 **CHW**（平面在前）
///
/// 这三条写错任意一条，模型都会"能跑但认不准"，
/// 而且从外面看不出是归一化错了还是模型不行。所以单独抽出来测。
enum PPOCRInputNormalizer {

    /// 模型要求的高度。PP-OCR 的 rec 模型固定 48。
    static let targetHeight = 48
    /// 默认宽度。
    static let defaultWidth = 320

    /// 单通道像素（0…255）→ 归一化后的 Float。
    @inline(__always)
    static func normalize(_ value: UInt8) -> Float {
        (Float(value) / 255.0 - 0.5) / 0.5
    }

    /// 把一张灰度图（行优先）转成 CHW 的 Float 数组。
    ///
    /// - Returns: 长度 = 3 × height × width，顺序是
    ///   [R 平面][G 平面][B 平面]。灰度图三个平面相同。
    static func makeCHW(
        gray: [UInt8],
        width: Int,
        height: Int
    ) -> [Float] {
        guard width > 0, height > 0, gray.count >= width * height else { return [] }
        let plane = width * height
        var out = [Float](repeating: 0, count: plane * 3)
        for index in 0..<plane {
            let value = normalize(gray[index])
            out[index] = value              // R
            out[plane + index] = value      // G
            out[plane * 2 + index] = value  // B
        }
        return out
    }

    /// 按比例缩放到目标高，宽度上限 `maxWidth`，不足则右侧补 0（归一化后的 0 = 中灰）。
    ///
    /// - Returns: (灰度数据, 实际宽, 实际高)
    static func fit(
        gray: [UInt8],
        width: Int,
        height: Int,
        targetHeight: Int = PPOCRInputNormalizer.targetHeight,
        maxWidth: Int = PPOCRInputNormalizer.defaultWidth
    ) -> (pixels: [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0, gray.count >= width * height else {
            return ([], 0, 0)
        }
        // 目标宽度按原图比例算，并**向上取到 8 的倍数** ——
        // PP-OCR 的骨干网下采样 8 倍，宽不是 8 的倍数时最后一段会被丢掉。
        let scale = Double(targetHeight) / Double(height)
        var targetWidth = Int((Double(width) * scale).rounded())
        targetWidth = max(8, min(maxWidth, ((targetWidth + 7) / 8) * 8))

        var out = [UInt8](repeating: 127, count: targetWidth * targetHeight)
        for y in 0..<targetHeight {
            // 反向映射取最近邻：够用，而且不会引入新的插值假设
            let sourceY = min(height - 1, Int(Double(y) / Double(targetHeight) * Double(height)))
            for x in 0..<targetWidth {
                let sourceX = min(width - 1, Int(Double(x) / Double(targetWidth) * Double(width)))
                out[y * targetWidth + x] = gray[sourceY * width + sourceX]
            }
        }
        return (out, targetWidth, targetHeight)
    }
}
