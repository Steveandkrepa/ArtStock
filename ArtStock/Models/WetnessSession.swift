//
//  WetnessSession.swift
//  ArtAssist — 美术生的工具箱
//
//  一次"颜料保湿监测"的完整记录。
//
//  同时承担两件事：
//    1. 计时器状态 —— 正在监测的会话、什么时候该补水
//    2. 实测校准的数据源 —— 用户观测到的真实时长存在这里，
//       反推出的 K 也回写到这里，形成可追溯的校准历史
//
//  ⚠️ calibrationUsed 存的是**基础常数 K**（不含容器保湿倍数）。
//     容器倍数由 closure 单独表示，在 DryingModel.forecast 里才乘上去。
//     如果把已经乘过倍数的"有效常数"存进来，重算时会重复计入容器影响。
//

import Foundation
import SwiftData

enum WetnessStatus: String, CaseIterable, Codable, Identifiable, Sendable {
    case running
    case misted
    case finished
    case abandoned

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .running: return "监测中"
        case .misted: return "已补水"
        case .finished: return "已结束"
        case .abandoned: return "已放弃"
        }
    }

    var symbolName: String {
        switch self {
        case .running: return "drop.circle.fill"
        case .misted: return "checkmark.circle.fill"
        case .finished: return "flag.checkered"
        case .abandoned: return "xmark.circle"
        }
    }

    var isActive: Bool { self == .running || self == .misted }
}

@Model
final class WetnessSession {

    // MARK: 时间

    var startedAt: Date
    var endedAt: Date?

    // MARK: 环境

    var temperatureC: Double
    var relativeHumidity: Double
    /// 湿度是怎么来的 —— 便于事后判断这次预测可信不可信。
    var humiditySource: String
    /// 用户有没有在开始前手动修正过天气数据。
    var wasManuallyAdjusted: Bool
    var placeName: String

    // MARK: 颜料与容器

    var paintSystemRaw: String
    var closureRaw: String

    // MARK: 模型参数

    /// 基础标定常数 K（kPa·h），**不含**容器倍数。见文件头说明。
    var calibrationUsed: Double
    var wasCalibrated: Bool

    // MARK: 冻结的历史预测

    /// 建模当时的建议补水时刻。存下来而不是每次重算，
    /// 这样事后回看看到的是"当时预测了什么"，而不是被新参数改写的结果。
    var predictedRemistAt: Date
    var predictedSkinningAt: Date
    var spraysPerRemist: Int

    // MARK: 状态

    var statusRaw: String
    var mistCount: Int
    var note: String

    // MARK: 实测校准

    /// 用户点下"现在需要补水了"的真实时刻。
    var observedRemistAt: Date?
    /// 由这次观测反推出的 K。
    var derivedCalibration: Double?

    init(
        startedAt: Date = .now,
        temperatureC: Double,
        relativeHumidity: Double,
        humiditySource: String,
        wasManuallyAdjusted: Bool = false,
        placeName: String,
        paintSystem: PaintSystem,
        closure: PaletteClosure,
        calibrationUsed: Double,
        wasCalibrated: Bool,
        predictedRemistAt: Date,
        predictedSkinningAt: Date,
        spraysPerRemist: Int,
        status: WetnessStatus = .running,
        note: String = ""
    ) {
        self.startedAt = startedAt
        self.temperatureC = temperatureC
        self.relativeHumidity = relativeHumidity
        self.humiditySource = humiditySource
        self.wasManuallyAdjusted = wasManuallyAdjusted
        self.placeName = placeName
        self.paintSystemRaw = paintSystem.rawValue
        self.closureRaw = closure.rawValue
        self.calibrationUsed = calibrationUsed
        self.wasCalibrated = wasCalibrated
        self.predictedRemistAt = predictedRemistAt
        self.predictedSkinningAt = predictedSkinningAt
        self.spraysPerRemist = spraysPerRemist
        self.statusRaw = status.rawValue
        self.mistCount = 0
        self.note = note
    }

    /// 用一次预报创建会话。
    static func make(
        forecast: DryingForecast,
        input: DryingInput,
        humiditySource: String,
        wasManuallyAdjusted: Bool,
        placeName: String
    ) -> WetnessSession {
        WetnessSession(
            startedAt: input.startedAt,
            temperatureC: input.temperatureC,
            relativeHumidity: input.relativeHumidity,
            humiditySource: humiditySource,
            wasManuallyAdjusted: wasManuallyAdjusted,
            placeName: placeName,
            paintSystem: input.paintSystem,
            closure: input.closure,
            // 存基础常数，不含容器倍数
            calibrationUsed: input.calibrationOverride ?? input.paintSystem.defaultCalibration,
            wasCalibrated: forecast.isCalibrated,
            predictedRemistAt: forecast.remistDeadline,
            predictedSkinningAt: input.startedAt.addingTimeInterval(forecast.skinningHours * 3600),
            spraysPerRemist: forecast.spraysPerRemist
        )
    }
}

// MARK: - 枚举桥接

extension WetnessSession {

    var paintSystem: PaintSystem {
        get { PaintSystem(rawValue: paintSystemRaw) ?? .other }
        set { paintSystemRaw = newValue.rawValue }
    }

    var closure: PaletteClosure {
        get { PaletteClosure(rawValue: closureRaw) ?? .open }
        set { closureRaw = newValue.rawValue }
    }

    var status: WetnessStatus {
        get { WetnessStatus(rawValue: statusRaw) ?? .finished }
        set { statusRaw = newValue.rawValue }
    }
}

// MARK: - 派生状态

extension WetnessSession {

    /// 按当前参数重算预报。用于界面实时显示剩余时间。
    ///
    /// 注意与 `predictedRemistAt` 的区别：后者是**冻结的历史记录**，
    /// 这里是**实时值**。改了湿度或容器之后两者会分叉，这是刻意的。
    var currentForecast: DryingForecast {
        DryingModel.forecast(DryingInput(
            temperatureC: temperatureC,
            relativeHumidity: relativeHumidity,
            paintSystem: paintSystem,
            closure: closure,
            calibrationOverride: wasCalibrated ? calibrationUsed : nil,
            minutesPerSpray: WetnessPreferences.minutesPerSpray,
            startedAt: startedAt
        ))
    }

    var timeUntilRemist: TimeInterval {
        predictedRemistAt.timeIntervalSinceNow
    }

    var isOverdue: Bool {
        status.isActive && timeUntilRemist < 0
    }

    var overdueInterval: TimeInterval {
        max(0, -timeUntilRemist)
    }

    /// 紧急程度 0–1：0 = 刚洗完，1 = 已达/超过补水时刻。
    var urgency: Double {
        let total = predictedRemistAt.timeIntervalSince(startedAt)
        guard total > 0 else { return 1 }
        return min(max(Date.now.timeIntervalSince(startedAt) / total, 0), 1)
    }

    var statusSummary: String {
        switch status {
        case .finished: return "已结束"
        case .abandoned: return "已放弃"
        case .running, .misted:
            if isOverdue { return "已超过 \(Fmt.duration(overdueInterval))" }
            return "还有 \(Fmt.duration(timeUntilRemist))"
        }
    }

    /// 这次观测的时长（小时）。用于校准。
    var observedHours: Double? {
        guard let observedRemistAt else { return nil }
        let hours = observedRemistAt.timeIntervalSince(startedAt) / 3600
        return hours > 0 ? hours : nil
    }
}
