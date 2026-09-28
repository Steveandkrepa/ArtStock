//
//  StartSessionSheet.swift
//  ArtAssist — 美术生的工具箱
//
//  开始一次保湿监测。
//
//  ── 这个面板的设计要点 ───────────────────────────────────────
//  湿度来自天气 API，但**默认值允许拖动修正**，而且这件事被明确写在界面上。
//  原因：室外湿度和画室里的湿度能差二三十个百分点（空调、暖气、门窗、洗笔筒）。
//  如果把这个数字当成真值直接用，模型再准也是错的。
//  所以这里不是"设置项"，而是流程的必经一步：看一眼，不对就改。
//

import SwiftData
import SwiftUI

struct StartSessionSheet: View {

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// 由外部传入，避免每次开面板都新建一个（那会丢掉已取到的快照）。
    let weather: WeatherService

    @State private var paintSystem: PaintSystem = WetnessPreferences.defaultPaintSystem
    @State private var closure: PaletteClosure = WetnessPreferences.defaultClosure

    @State private var temperature: Double = 22
    @State private var humidity: Double = 50
    @State private var hasLoadedWeather = false
    @State private var wasAdjusted = false
    @State private var loadError: String?

    @State private var isShowingCalibration = false

    private var calibration: Double? {
        WetnessPreferences.calibration(for: paintSystem)
    }

    private var input: DryingInput {
        DryingInput(
            temperatureC: temperature,
            relativeHumidity: humidity,
            paintSystem: paintSystem,
            closure: closure,
            calibrationOverride: calibration,
            minutesPerSpray: WetnessPreferences.minutesPerSpray,
            startedAt: .now
        )
    }

    private var forecast: DryingForecast {
        DryingModel.forecast(input)
    }

    var body: some View {
        NavigationStack {
            Form {
                weatherSection
                adjustSection
                paintSection
                predictionSection
                calibrationSection
            }
            .formStyle(.grouped)
            .navigationTitle("开始保湿计时")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("开始") { start() }
                        .fontWeight(.semibold)
                }
            }
            .task { await loadWeather() }
            .sheet(isPresented: $isShowingCalibration) {
                CalibrationSheet(paintSystem: paintSystem, closure: closure,
                                 temperatureC: temperature, relativeHumidity: humidity)
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - 天气

    private var weatherSection: some View {
        Section {
            if let snapshot = weather.snapshot {
                InfoRow(label: "地点", value: snapshot.placeName, symbolName: "location")
                InfoRow(label: "数据来源", value: snapshot.sourceDescription,
                        symbolName: "antenna.radiowaves.left.and.right")
                InfoRow(label: "取样时间", value: Fmt.relative(snapshot.fetchedAt), symbolName: "clock")
            } else if weather.state.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在取当地天气…").foregroundStyle(.secondary)
                }
            } else if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("还没取到天气。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await loadWeather(force: true) }
            } label: {
                Label("重新获取天气", systemImage: "arrow.clockwise")
            }
            .disabled(weather.state.isLoading)
        } header: {
            Text("当地天气")
        } footer: {
            Text("湿度来自 Open-Meteo 公开接口，不联网就用不了。下面可以直接改。")
        }
    }

    // MARK: - 修正

    private var adjustSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("湿度")
                    Spacer()
                    Text("\(Int(humidity.rounded())) %")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
                Slider(value: Binding(
                    get: { humidity },
                    set: { humidity = $0; wasAdjusted = true }
                ), in: 5...100, step: 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("温度")
                    Spacer()
                    Text("\(Fmt.number(temperature, maximumFractionDigits: 1)) ℃")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
                Slider(value: Binding(
                    get: { temperature },
                    set: { temperature = $0; wasAdjusted = true }
                ), in: 0...45, step: 0.5)
            }
        } header: {
            Text("确认一下")
        } footer: {
            Text(wasAdjusted
                 ? "已按你的修正计算。"
                 : "室外天气数据，画室里可能差不少 —— 不对就拖一下。")
        }
    }

    // MARK: - 颜料与容器

    private var paintSection: some View {
        Section {
            Picker("颜料", selection: $paintSystem) {
                ForEach(PaintSystem.allCases) { system in
                    Label(system.displayName, systemImage: system.symbolName).tag(system)
                }
            }
            .onChange(of: paintSystem) { _, newValue in
                WetnessPreferences.defaultPaintSystem = newValue
            }

            Picker("放置方式", selection: $closure) {
                ForEach(PaletteClosure.allCases) { item in
                    Label(item.displayName, systemImage: item.symbolName).tag(item)
                }
            }
            .onChange(of: closure) { _, newValue in
                WetnessPreferences.defaultClosure = newValue
            }
        } header: {
            Text("颜料与容器")
        } footer: {
            Text(paintSystem.calibrationNote + "　" + closure.note)
        }
    }

    // MARK: - 预测

    private var predictionSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Text("建议补水")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.duration(forecast.remistDeadline.timeIntervalSince(forecast.startedAt)))
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .foregroundStyle(.orange)
            }

            InfoRow(label: "完全结皮",
                    value: "约 " + Fmt.duration(forecast.skinningHours * 3600) + " 后",
                    symbolName: "clock.badge.exclamationmark")

            if forecast.spraysPerRemist > 0 {
                InfoRow(label: "每次喷雾", value: "\(forecast.spraysPerRemist) 下",
                        symbolName: "spraybottle.fill", tint: .blue)
            } else {
                Label("还没标定「喷一下能维持多久」，所以只给时间提醒、不给下数",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup("预测依据") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(forecast.notes, id: \.self) { note in
                        Text("· " + note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(String(format: "水汽压差 VPD ≈ %.2f kPa", forecast.vaporPressureDeficit))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
            }
            .font(.subheadline)
        } header: {
            Text("预计")
        }
    }

    // MARK: - 校准

    private var calibrationSection: some View {
        Section {
            HStack {
                Label(calibration == nil ? "未校准" : "已校准",
                      systemImage: calibration == nil ? "questionmark.circle" : "checkmark.seal.fill")
                    .foregroundStyle(calibration == nil ? .orange : .green)
                Spacer()
                if let calibration {
                    Text(String(format: "K = %.1f", calibration))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                isShowingCalibration = true
            } label: {
                Label(calibration == nil ? "做一次实测校准（1 分钟）" : "重新校准",
                      systemImage: "ruler")
            }

            if calibration != nil {
                Button(role: .destructive) {
                    WetnessPreferences.setCalibration(nil, for: paintSystem)
                } label: {
                    Label("清除这个颜料的校准值", systemImage: "arrow.counterclockwise")
                }
                .font(.subheadline)
            }
        } header: {
            Text("精度")
        } footer: {
            Text(calibration == nil
                 ? "当前用的是「\(paintSystem.displayName)」的默认起点常数，不是你的真实值。做完一次校准会准很多。"
                 : "已使用你实测校准的常数，预测更贴近你的实际环境。")
        }
    }

    // MARK: - 动作

    private func loadWeather(force: Bool = false) async {
        loadError = nil
        do {
            let snapshot = try await weather.currentOrFetch()
            // 用户已经修正过就不再覆盖，尊重他的输入。
            if !hasLoadedWeather || !wasAdjusted {
                temperature = snapshot.temperatureC
                humidity = snapshot.relativeHumidity
            }
            hasLoadedWeather = true
        } catch {
            if !hasLoadedWeather {
                // 取不到也要能用 —— 留一个合理默认值让用户自己拖。
                temperature = 22
                humidity = 50
                hasLoadedWeather = true
                loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func start() {
        let f = forecast
        let session = WetnessSession.make(
            forecast: f,
            input: input,
            humiditySource: weather.snapshot?.sourceDescription ?? "手动设定",
            wasManuallyAdjusted: wasAdjusted,
            placeName: weather.snapshot?.placeName ?? "未指定"
        )
        context.insert(session)
        try? context.save()

        Task { await NotificationService.scheduleReminder(for: session) }
        Haptics.saved()
        dismiss()
    }
}
