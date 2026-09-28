//
//  WetnessView.swift
//  ArtAssist — 美术生的工具箱
//
//  颜料湿润计时器的主界面。
//
//  一屏只说一件事：**还有多久该喷水**。
//  所以最上面是一个大倒计时，其余信息全部退到次要位置。
//  没在计时的时候，就一个「开始」按钮加一段历史。
//

import Combine
import SwiftData
import SwiftUI

struct WetnessView: View {

    @Environment(\.modelContext) private var context

    @Query(sort: \WetnessSession.startedAt, order: .reverse)
    private var sessions: [WetnessSession]

    @State private var weather = WeatherService()
    @State private var pip = WetnessPiPController()
    @State private var pipMessage: String?
    @State private var isShowingStart = false
    @State private var calibrationResult: CalibrationResult?
    @State private var outcomeMessage: String?

    private var activeSession: WetnessSession? {
        sessions.first { $0.status.isActive }
    }

    private var history: [WetnessSession] {
        sessions.filter { !$0.status.isActive }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let session = activeSession {
                    ActiveSessionCard(
                        session: session,
                        pip: pip,
                        onMist: { mist(session) },
                        onObserveDry: { observeDry(session) },
                        onFinish: {
                            pip.stop()
                            finish(session, status: .finished)
                        },
                        onAbandon: {
                            pip.stop()
                            finish(session, status: .abandoned)
                        },
                        // 参数顺序必须与声明一致：pipFailure 在最后。
                        pipFailure: { pipMessage = $0 }
                    )
                } else {
                    idleCard
                }

                if !history.isEmpty {
                    historySection
                }
            }
            .padding(20)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .artScrollEdgeEffect()
        .navigationTitle("保湿计时")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // 每次打开顺手刷一次天气，让「开始」面板里的数字是新的。
            Task { await weather.refresh() }
            // 把画中画的失败原因接到弹窗上 —— 之前这条通路没接，
            // 所以启动失败时界面"点了没反应"。
            pip.onError = { message in pipMessage = message }
        }
        .sheet(isPresented: $isShowingStart) {
            StartSessionSheet(weather: weather)
        }
        .sheet(item: $calibrationResult) { result in
            CalibrationSuggestionSheet(result: result)
        }
        .alert("画中画", isPresented: .presentWhen($pipMessage)) {
            Button("好") { pipMessage = nil }
        } message: {
            Text(pipMessage ?? "")
        }
        .alert("已完成", isPresented: .presentWhen($outcomeMessage)) {
            Button("好") { outcomeMessage = nil }
        } message: {
            Text(outcomeMessage ?? "")
        }
    }

    // MARK: - 未计时

    private var idleCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("现在没有在计时", systemImage: "timer")
                .font(.headline)

            Text("调好一盘颜色要离开一段时间时，开个计时。到点会本地提醒你该喷水了。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                isShowingStart = true
            } label: {
                Label("开始保湿计时", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .artProminentButton()
            .controlSize(.large)

            Divider()

            HStack(spacing: 16) {
                settingChip(title: "颜料", value: WetnessPreferences.defaultPaintSystem.displayName)
                settingChip(title: "放置", value: WetnessPreferences.defaultClosure.displayName)
                settingChip(title: "喷雾",
                            value: WetnessPreferences.hasSprayCalibration
                                ? "\(Int(WetnessPreferences.minutesPerSpray)) 分/下" : "未标定")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func settingChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 历史

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "历史", subtitle: "最近 \(min(history.count, 10)) 次")

            VStack(spacing: 0) {
                ForEach(Array(history.prefix(10).enumerated()), id: \.element.id) { index, session in
                    HStack(spacing: 12) {
                        Image(systemName: session.status.symbolName)
                            .foregroundStyle(session.status == .finished ? .green : .secondary)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(session.paintSystem.displayName) · \(session.closure.displayName)")
                                .font(.subheadline.weight(.medium))
                            HStack(spacing: 6) {
                                Text(Fmt.dateTime(session.startedAt))
                                if session.mistCount > 0 {
                                    Text("· 补过 \(session.mistCount) 次")
                                }
                                if let derived = session.derivedCalibration {
                                    Text(String(format: "· 校准 K=%.1f", derived))
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }

                        Spacer(minLength: 8)

                        Text(Fmt.duration(session.predictedRemistAt.timeIntervalSince(session.startedAt)))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(role: .destructive) {
                            NotificationService.cancelReminder(for: session)
                            context.delete(session)
                            try? context.save()
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 9)

                    if index < min(history.count, 10) - 1 {
                        Divider().padding(.leading, 36)
                    }
                }
            }
            .cardStyle(padding: 12)
        }
    }

    // MARK: - 动作

    private func mist(_ session: WetnessSession) {
        session.mistCount += 1
        session.status = .misted
        // 喷完水重新起算：把开始时刻挪到现在，并按当前条件重排提醒。
        let forecast = session.currentForecast
        let newDeadline = Date.now.addingTimeInterval(
            forecast.remistDeadline.timeIntervalSince(forecast.startedAt)
        )
        session.predictedRemistAt = newDeadline
        session.startedAt = .now
        try? context.save()

        Task { await NotificationService.scheduleReminder(for: session) }
        Haptics.saved()
        outcomeMessage = "已记一次补水。下一次提醒：\(Fmt.duration(newDeadline.timeIntervalSinceNow))后。"
    }

    /// 用户报告"现在已经真的干了"。这是校准的数据来源 —— 比任何公式都准。
    private func observeDry(_ session: WetnessSession) {
        session.observedRemistAt = .now

        let hours = session.observedHours ?? 0
        let derived = DryingModel.calibrate(
            observedHours: hours,
            temperatureC: session.temperatureC,
            relativeHumidity: session.relativeHumidity,
            closure: session.closure
        )
        session.derivedCalibration = derived
        try? context.save()

        if let derived {
            calibrationResult = CalibrationResult(
                paintSystem: session.paintSystem,
                observedHours: hours,
                derived: derived,
                previous: WetnessPreferences.calibration(for: session.paintSystem)
            )
        } else {
            outcomeMessage = "记录了「\(Fmt.duration(hours * 3600))」这个时长，但算出来的常数不合理，这次就不拿来校准了。"
        }
    }

    private func finish(_ session: WetnessSession, status: WetnessStatus) {
        session.status = status
        session.endedAt = .now
        try? context.save()
        NotificationService.cancelReminder(for: session)
        Haptics.saved()
    }
}

// MARK: - 进行中的卡片

private struct ActiveSessionCard: View {

    let session: WetnessSession
    let pip: WetnessPiPController
    var onMist: () -> Void
    var onObserveDry: () -> Void
    var onFinish: () -> Void
    var onAbandon: () -> Void
    /// 画中画启动失败时把原因抛给上层去弹窗。
    var pipFailure: ((String) -> Void)?

    /// 每秒走一次，让倒计时真的在动。
    @State private var now = Date.now
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var remaining: TimeInterval {
        session.predictedRemistAt.timeIntervalSince(now)
    }

    private var urgency: Double {
        let total = session.predictedRemistAt.timeIntervalSince(session.startedAt)
        guard total > 0 else { return 1 }
        return min(max(now.timeIntervalSince(session.startedAt) / total, 0), 1)
    }

    /// 把会话状态翻译成画中画要显示的四个字段。
    private func makeContent() -> PiPContent {
        let remaining = session.predictedRemistAt.timeIntervalSinceNow
        let overdue = remaining < 0

        let text: String
        if overdue {
            text = "超 " + shortDuration(-remaining)
        } else {
            text = shortDuration(remaining)
        }

        return PiPContent(
            title: "\(session.paintSystem.displayName) · \(session.closure.displayName)",
            timeText: text,
            sprays: session.spraysPerRemist,
            urgency: session.urgency,
            isOverdue: overdue
        )
    }

    /// 画中画窗口很窄，时长必须用最短的写法：`2:14` / `1:03:20`。
    private func shortDuration(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var pipButtonTitle: String {
        if pip.isStarting { return "正在启动画中画…" }
        return pip.isActive ? "关闭画中画悬浮窗" : "在画中画里显示"
    }

    private var pipButtonSymbol: String {
        if pip.isStarting { return "hourglass" }
        return pip.isActive ? "pip.exit" : "pip.enter"
    }

    /// 不支持时把系统给的原话显示出来 —— 比笼统说一句"不支持"有用。
    private var pipUnavailableReason: String {
        pip.lastError ?? "这台设备或当前环境不支持画中画。"
    }

    private func togglePiP() {
        if pip.isActive {
            pip.stop()
        } else {
            let ok = pip.start { makeContent() }
            if !ok, let error = pip.lastError {
                pipFailure?(error)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: session.status.symbolName)
                    .foregroundStyle(remaining < 0 ? .red : Theme.accent)
                Text("\(session.paintSystem.displayName) · \(session.closure.displayName)")
                    .font(.headline)
                Spacer()
                if session.mistCount > 0 {
                    Text("补过 \(session.mistCount) 次")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 大倒计时 —— 这一屏唯一的主角
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(remaining < 0 ? "已超过" : "还有")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Fmt.duration(abs(remaining)))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(remaining < 0 ? .red : .primary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            ProgressView(value: urgency)
                .tint(remaining < 0 ? .red : (urgency > 0.75 ? .orange : Theme.accent))

            if session.spraysPerRemist > 0 {
                Label("建议喷 \(session.spraysPerRemist) 下", systemImage: "spraybottle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.blue)
            } else {
                Text("还没标定「喷一下能维持多久」，标定后这里会给出下数。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    onMist()
                } label: {
                    Label("我喷过水了", systemImage: "drop.fill")
                        .frame(maxWidth: .infinity)
                }
                .artProminentButton()
                .controlSize(.large)

                Button {
                    onObserveDry()
                } label: {
                    Label("其实已经干了", systemImage: "exclamationmark.triangle")
                        .frame(maxWidth: .infinity)
                }
                .artGlassButton()
                .controlSize(.large)
            }

            Divider()

            // 画中画预览区。
            //
            // ⚠️ 这个预览不是装饰 —— AVSampleBufferDisplayLayer **必须挂在
            //    屏幕上的视图层级里**，PiP 才可能启动。原来 layer 建出来没往
            //    任何 view 里放，导致 startPictureInPicture() 静默失败、
            //    界面上"点了没反应"。所以这里必须始终渲染它。
            if WetnessPiPController.isSupported {
                VStack(alignment: .leading, spacing: 6) {
                    Text("悬浮窗预览")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    PiPLayerHostView(displayLayer: pip.displayLayer)
                        .frame(width: 168, height: 95)
                        .onAppear { pip.primeDisplay(with: makeContent()) }
                        // 跟着每秒心跳走，预览才是"活的"
                        .onChange(of: now) { _, _ in
                            if !pip.isActive { pip.primeDisplay(with: makeContent()) }
                        }
                }
            }

            // 画中画：切到 Procreate 画画时也能看见还剩多久。
            //
            // 启动是异步的：系统要花几百毫秒才认为"可以起 PiP"，
            // 所以按钮上必须显示"正在启动"，否则用户会以为没反应又点一次。
            Button {
                togglePiP()
            } label: {
                Label(pipButtonTitle, systemImage: pipButtonSymbol)
                    .frame(maxWidth: .infinity)
            }
            .artGlassButton()
            .controlSize(.large)
            .disabled(pip.isStarting)

            if !WetnessPiPController.isSupported {
                Text(pipUnavailableReason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if pip.isActive {
                Text("已经把悬浮窗开起来了。切到别的 App 画画，它也会留在屏幕上。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("结束监测") { onFinish() }
                    .font(.subheadline)
                Button("放弃这次") { onAbandon() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Text("「其实已经干了」会记下真实时长，用来校准模型 —— 这比任何公式都准。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .onReceive(ticker) { now = $0 }
    }
}

// MARK: - 校准建议

struct CalibrationResult: Identifiable {
    var id: String { paintSystem.rawValue + String(observedHours) }
    var paintSystem: PaintSystem
    var observedHours: Double
    var derived: Double
    var previous: Double?
}

struct CalibrationSuggestionSheet: View {

    let result: CalibrationResult

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("你记录了真实的 \(Fmt.duration(result.observedHours * 3600)) 到该补水。"
                         + "用它可以反推出属于你的常数。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        Text("推算出的 K")
                        Spacer()
                        Text(String(format: "%.1f", result.derived))
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .foregroundStyle(.green)
                            .monospacedDigit()
                    }
                    if let previous = result.previous {
                        HStack {
                            Text("原来用的")
                            Spacer()
                            Text(String(format: "%.1f", previous))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } else {
                        HStack {
                            Text("原来用的")
                            Spacer()
                            Text("默认起点值")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("\(result.paintSystem.displayName) 的新常数")
                } footer: {
                    Text("保存后，以后用「\(result.paintSystem.displayName)」计时会按这个常数预测。随时可以重新校准。")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("拿这次校准？")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("先不用") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        WetnessPreferences.setCalibration(result.derived, for: result.paintSystem)
                        Haptics.saved()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
