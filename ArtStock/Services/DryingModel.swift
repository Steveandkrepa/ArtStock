//
//  DryingModel.swift
//  ArtAssist — 美术生的工具箱
//
//  颜料湿润计时器的计算内核。
//
//  ── 这个模型是怎么来的，以及它不是什么 ──────────────────────────
//
//  物理部分（有依据）：
//      饱和水汽压  es(T) = 0.6108 · exp(17.27·T / (T + 237.3))   [kPa]
//          —— Magnus 公式，气象与农业领域的标准经验式。
//      水汽压差    VPD = es(T) · (1 − RH/100)                    [kPa]
//          —— 即"当前空气还能容纳多少水汽"，是蒸发的真实驱动力。
//             农业与园艺普遍用它预测蒸腾与干燥速度。
//      失水速率 ∝ VPD，因此 结皮时间 t ≈ K / VPD。
//
//  标定部分（**没有**先验依据，必须实测）：
//      K 是"颜料体系 + 膜厚 + 容器"共同决定的常数，单位 kPa·h。
//      本文件给出的 K 默认值只是**起点猜测**，用于让用户第一次就能跑起来，
//      **不是**实验室标定值。真实使用必须走「实测校准」：
//          你记录一次从开始到需要补水的真实时长，
//          App 用 K = 实测时长 × 当时的 VPD 反推出属于你的 K。
//
//  刻意不做的：
//      · 不假装能算准具体分钟数。模型输出带的是**区间与假设说明**，
//        并且把用到的每一个经验系数都暴露出来。
//      · 不考虑颜料化学成分、膜厚微米数、通风风速这些拿不到的输入。
//        它们的影响被吸收进 K 里 —— 这正是必须校准的原因。
//
//  本文件只依赖 Foundation，因此可以在 macOS 上直接编译运行做回归测试
//  （见 scripts/run-model-tests.sh）。这是刻意保持的：模型是这个功能里
//  唯一能被真正验证的部分，不能让它依赖 UI 或 iOS SDK。
//

import Foundation

// MARK: - 颜料体系

/// 颜料体系。不同体系成膜机理不同，失水速度差异很大。
enum PaintSystem: String, CaseIterable, Codable, Identifiable, Sendable {
    /// 水粉。**美术生 42 色盒里装的就是它**，所以放在第一位、也是默认值。
    ///
    /// 特点：厚涂在格子里，表层水分蒸发极快， открыт状态下几十分钟就结膜。
    case gouache
    /// 水彩（固体块按设计就是要干透再复水，湿盘另说）
    case watercolor
    /// 丙烯（水分蒸发 + 聚合物成膜）
    case acrylic
    /// 油画（氧化结膜，最慢）
    case oil
    /// 蛋彩 / 坦培拉
    case tempera
    /// 其他 / 不确定
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gouache: return "水粉"
        case .watercolor: return "水彩"
        case .acrylic: return "丙烯"
        case .oil: return "油画"
        case .tempera: return "蛋彩"
        case .other: return "其他"
        }
    }

    var symbolName: String {
        switch self {
        case .gouache: return "drop.fill"
        case .watercolor: return "drop"
        case .acrylic: return "drop.triangle"
        case .oil: return "drop.triangle.fill"
        case .tempera: return "drop.halffull"
        case .other: return "questionmark.circle"
        }
    }

    /// 默认标定常数 K（kPa·h）。
    ///
    /// ⚠️ 这些数字是**起点**，不是测量结果 —— 但也不是拍脑袋：
    /// 水粉这一档是按真实使用体感校准的（开放盒、22℃ / 50% 湿度下，
    /// **大约 1 小时就需要喷一次水**）：
    ///        es(22℃) ≈ 2.64 kPa  →  VPD ≈ 1.32 kPa
    ///        remist = K / VPD × 0.5 = 1 h   →   K ≈ 2.6
    ///
    /// 早期版本这里错得离谱：水粉被并进"水彩"且 K=8（预测 3 小时），
    /// 默认容器又是"密闭盒"（再放大 2.6 倍）—— 叠起来把时间高估了 8 倍以上，
    /// 用户实测"最多 1 小时"而 App 说"6 小时"。这两个错误都已修正。
    ///
    /// 其它体系仍是粗估，**做完一次实测校准最准**。
    var defaultCalibration: Double {
        switch self {
        case .gouache: return 2.6
        case .watercolor: return 4
        case .acrylic: return 10
        case .oil: return 30
        case .tempera: return 8
        case .other: return 6
        }
    }

    var calibrationNote: String {
        switch self {
        case .gouache: return "厚涂在格子里表层失水极快，开放放置几十分钟就结膜"
        case .watercolor: return "固体块本来就是要干透再复水的；湿盘会快很多"
        case .acrylic: return "水分蒸发 + 聚合物聚结成膜，表干很快"
        case .oil: return "氧化结膜为主，表层结皮比内部干燥快得多"
        case .tempera: return "水性乳液体系，介于丙烯与水彩之间"
        case .other: return "不确定就选它，然后用实测校准把常数调准"
        }
    }
}

// MARK: - 调色板封闭方式

/// 调色板的保湿方式。同样条件下，密闭与开放能差好几倍。
enum PaletteClosure: String, CaseIterable, Codable, Identifiable, Sendable {
    /// 开放调色板（完全暴露在空气里）
    case open
    /// 密闭调色盒 / 密封箱
    case sealedBox
    /// 湿盘 / 保湿海绵垫
    case wetPad
    /// 盖了保鲜膜但没密封
    case looseCover

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .open: return "开放放置"
        case .sealedBox: return "密闭调色盒"
        case .wetPad: return "湿盘 / 保湿海绵"
        case .looseCover: return "覆盖未密封"
        }
    }

    var symbolName: String {
        switch self {
        case .open: return "tray"
        case .sealedBox: return "shippingbox"
        case .wetPad: return "square.stack.3d.up"
        case .looseCover: return "rectangle.portrait"
        }
    }

    /// 保湿倍数：把基线时长乘上它。
    ///
    /// ⚠️ 同样是**经验倍数**，不是测量值。密闭盒的密闭程度、
    ///    湿盘海绵的含水量差异都会显著影响它。实测校准会把这些一并吸收进 K，
    ///    所以校准后请不要再随意切换这里的选择。
    var retentionFactor: Double {
        switch self {
        case .open: return 1.0
        case .looseCover: return 1.6
        case .sealedBox: return 2.6
        case .wetPad: return 3.2
        }
    }

    var note: String {
        switch self {
        case .open: return "基线"
        case .looseCover: return "挡灰尘，但几乎不挡水汽"
        case .sealedBox: return "水汽基本不外逸，效果最明显"
        case .wetPad: return "海绵持续供水，适合短期停笔"
        }
    }
}

// MARK: - 输入

/// 一次湿润监测的输入条件。
struct DryingInput: Equatable, Sendable {
    /// 环境温度（摄氏度）。
    var temperatureC: Double
    /// 相对湿度（0–100）。
    var relativeHumidity: Double
    /// 颜料体系。
    var paintSystem: PaintSystem
    /// 调色板封闭方式。
    var closure: PaletteClosure
    /// 用户实测校准得到的 K。nil 表示用颜料体系的默认起点值。
    var calibrationOverride: Double?
    /// 一下喷雾大约能维持多少分钟（用户标定）。0 表示未标定。
    var minutesPerSpray: Double
    /// 本次计时开始时刻。
    var startedAt: Date

    init(
        temperatureC: Double,
        relativeHumidity: Double,
        paintSystem: PaintSystem,
        closure: PaletteClosure,
        calibrationOverride: Double? = nil,
        minutesPerSpray: Double = 0,
        startedAt: Date = .now
    ) {
        self.temperatureC = temperatureC
        self.relativeHumidity = relativeHumidity
        self.paintSystem = paintSystem
        self.closure = closure
        self.calibrationOverride = calibrationOverride
        self.minutesPerSpray = minutesPerSpray
        self.startedAt = startedAt
    }
}

// MARK: - 输出

/// 模型给出的预测。所有时间点都是绝对值，方便直接拿去排通知。
struct DryingForecast: Equatable, Sendable {

    /// 本次计时的开始时刻。预测里的所有时间点都相对它计算。
    /// 存下来是为了让界面和通知都能直接引用，不必层层传参。
    var startedAt: Date

    /// 饱和水汽压 es(T)，kPa。
    var saturationVaporPressure: Double
    /// 水汽压差 VPD，kPa。蒸发驱动力。
    var vaporPressureDeficit: Double
    /// 本次实际使用的标定常数 K（kPa·h）。
    var effectiveCalibration: Double
    /// 是否用了用户实测校准过的 K。
    var isCalibrated: Bool

    /// 到"表层完全结皮、不可再用"的预计时长（小时）。
    var skinningHours: Double
    /// 到"应该补水"的建议时刻。
    var remistDeadline: Date
    /// 提前预警时刻（用来给通知留缓冲）。
    var preWarnAt: Date
    /// 建议的补水间隔（分钟）。
    var remistIntervalMinutes: Double
    /// 每次建议喷雾下数。0 表示用户还没标定"一下能维持多久"。
    var spraysPerRemist: Int

    /// 模型自身给出的假设与注意事项，直接展示给用户。
    var notes: [String]

    /// 建议窗口的时长（从开始到该补水的分钟数）。
    var windowMinutes: Double {
        remistDeadline.timeIntervalSinceNow / 60
    }
}

// MARK: - 计算器

enum DryingModel {

    /// 相对湿度下限（%）。低于它按它算：极端干燥下 VPD 会趋于无穷，
    /// 时长会趋近 0，给出"几分钟就干"这种没有操作意义的结果。
    static let minimumHumidity: Double = 5

    /// VPD 下限（kPa）。防止除零与"时间趋近 0"。
    static let minimumVPD: Double = 0.02

    /// VPD 上限（kPa）。真实大气里极少超过 6 kPa，超过说明数据有问题。
    static let maximumVPD: Double = 8.0

    /// 建议补水点落在结皮时长的哪个比例上。
    ///
    /// 0.5 的含义：等到"还有一半时间就要完全结皮"时补水。
    /// 取半而不是取满，是因为结皮一旦开始就**不可逆** ——
    /// 表层起皮之后再怎么喷水也回不去，所以必须在不可逆之前动手。
    static let remistFraction: Double = 0.5

    /// 提前预警的比例（相对补水时刻）。
    static let preWarnFraction: Double = 0.85

    // MARK: 物理式

    /// 饱和水汽压（Magnus 公式），单位 kPa。
    /// - Parameter temperatureC: 摄氏温度。
    static func saturationVaporPressure(temperatureC: Double) -> Double {
        0.6108 * exp(17.27 * temperatureC / (temperatureC + 237.3))
    }

    /// 水汽压差 VPD，单位 kPa。
    ///
    /// 这是本模型的物理基础：VPD 越大，空气"抢水"的能力越强，颜料失水越快。
    static func vaporPressureDeficit(temperatureC: Double, relativeHumidity: Double) -> Double {
        let humidity = min(max(relativeHumidity, minimumHumidity), 100)
        let es = saturationVaporPressure(temperatureC: temperatureC)
        let raw = es * (1 - humidity / 100)
        return min(max(raw, minimumVPD), maximumVPD)
    }

    // MARK: 预测

    /// 根据输入给出预测。
    static func forecast(_ input: DryingInput) -> DryingForecast {

        let vpd = vaporPressureDeficit(
            temperatureC: input.temperatureC,
            relativeHumidity: input.relativeHumidity
        )
        let es = saturationVaporPressure(temperatureC: input.temperatureC)

        let isCalibrated = (input.calibrationOverride ?? 0) > 0
        let baseCalibration = isCalibrated
            ? (input.calibrationOverride ?? input.paintSystem.defaultCalibration)
            : input.paintSystem.defaultCalibration

        // 保湿倍数作用在总时长上，等价于把"有效常数"放大。
        let effectiveK = baseCalibration * input.closure.retentionFactor

        let skinningHours = max(effectiveK / vpd, 0.05)
        let remistHours = skinningHours * remistFraction

        let started = input.startedAt
        let deadline = started.addingTimeInterval(remistHours * 3600)
        let preWarn = started.addingTimeInterval(remistHours * preWarnFraction * 3600)

        // 补水间隔：第一次补水之后，按同样的物理节奏继续，
        // 但每次补水本身会补回一部分水汽，所以间隔按 60% 递减保守估计。
        let intervalMinutes = max(remistHours * 60 * 0.6, 10)

        var sprays = 0
        if input.minutesPerSpray > 0 {
            sprays = Int(ceil(intervalMinutes / input.minutesPerSpray))
            sprays = min(max(sprays, 1), 20)
        }

        return DryingForecast(
            startedAt: started,
            saturationVaporPressure: es,
            vaporPressureDeficit: vpd,
            effectiveCalibration: effectiveK,
            isCalibrated: isCalibrated,
            skinningHours: skinningHours,
            remistDeadline: deadline,
            preWarnAt: preWarn,
            remistIntervalMinutes: intervalMinutes,
            spraysPerRemist: sprays,
            notes: buildNotes(input: input, vpd: vpd, isCalibrated: isCalibrated, sprays: sprays)
        )
    }

    // MARK: 实测校准

    /// 由一次真实观测反推标定常数。
    ///
    /// 用户观测到的量是「多久之后需要补水」，也就是 forecast 里的 **补水间隔**，
    /// 而不是完整结皮时长。两者的关系是：
    ///     补水间隔 = 结皮时长 × remistFraction
    ///              = (K × 保湿倍数 / VPD) × remistFraction
    /// 因此反推时必须把 remistFraction 也除回去：
    ///     K = 实测时长(h) × VPD(kPa) ÷ 保湿倍数 ÷ remistFraction
    ///
    /// ⚠️ 这里踩过一个真实的坑，由测试用例 `回环一致性` 抓出来：
    ///    早期版本漏除了 remistFraction，导致"实测 10 小时"校准后
    ///    预测出来只有 5 小时 —— 正好差一倍。保湿倍数同理，
    ///    不除回去会让换容器后的预测重复计入容器影响。
    ///
    /// - Parameters:
    ///   - observedHours: 实测的、从开始到"该补水"的真实时长（小时）。
    ///   - temperatureC: 这段时间的代表温度。
    ///   - relativeHumidity: 这段时间的代表湿度。
    ///   - closure: 当时用的容器。
    /// - Returns: 反推得到的 K；输入不合理时返回 nil。
    static func calibrate(
        observedHours: Double,
        temperatureC: Double,
        relativeHumidity: Double,
        closure: PaletteClosure
    ) -> Double? {
        guard observedHours > 0.05, observedHours < 24 * 30 else { return nil }

        let vpd = vaporPressureDeficit(
            temperatureC: temperatureC,
            relativeHumidity: relativeHumidity
        )
        let factor = max(closure.retentionFactor, 0.1)
        let k = observedHours * vpd / factor / remistFraction

        // 合理性护栏：K 落在 1–500 kPa·h 之外基本可以断定输入有误
        // （例如把"完全干透"当成了"该补水"，两者差 2 倍；
        //   或者把湿度记反了，那会差更多）。
        guard k.isFinite, k > 1.0, k < 500 else { return nil }
        return k
    }

    /// 由"喷一下能维持多久"的实测反推每次间隔该喷几下。
    static func sprays(forIntervalMinutes interval: Double, minutesPerSpray: Double) -> Int {
        guard minutesPerSpray > 0, interval > 0 else { return 0 }
        return min(max(Int(ceil(interval / minutesPerSpray)), 1), 20)
    }

    // MARK: 说明文案

    private static func buildNotes(
        input: DryingInput,
        vpd: Double,
        isCalibrated: Bool,
        sprays: Int
    ) -> [String] {
        var notes: [String] = []

        notes.append(String(
            format: "当前水汽压差 VPD ≈ %.2f kPa（%.0f℃ / %.0f%% 湿度）",
            vpd, input.temperatureC, input.relativeHumidity
        ))

        if isCalibrated {
            notes.append("已使用你实测校准的常数，预测更贴近你的实际环境。")
        } else {
            notes.append("⚠️ 当前用的是「\(input.paintSystem.displayName)」的默认起点常数，"
                         + "不是你的真实值。做过一次实测校准后预测会准很多。")
        }

        if input.relativeHumidity >= 85 {
            notes.append("湿度很高，失水很慢。注意别让颜料长期过湿 —— 油画可能发霉，丙烯可能分层。")
        } else if input.relativeHumidity <= 25 {
            notes.append("空气非常干燥，失水很快，建议缩短补水间隔并贴紧容器。")
        }

        if vpd >= maximumVPD * 0.9 {
            notes.append("湿度/温度组合异常（VPD 已触顶），请核对数据来源是否合理。")
        }

        switch input.paintSystem {
        case .oil:
            notes.append("油画表层结皮不可逆：一旦起皮，补水也回不去，所以才按一半时长就提醒。")
        case .watercolor, .acrylic:
            notes.append("水性体系可以直接补水复活；即使超时，加一点水通常还能救回来。")
        default:
            break
        }

        if sprays == 0 {
            notes.append("还没标定「喷一下能维持多久」，所以只给时间提醒、不给喷雾下数。"
                         + "在设置里花一分钟标定即可。")
        }

        return notes
    }
}
