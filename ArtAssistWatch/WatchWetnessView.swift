//
//  WatchWetnessView.swift
//  ArtAssist — 美术生的工具箱（Apple Watch 端）
//
//  保湿计时：调完色点开始，到点前震一下提醒补喷水。
//
//  ── 交互为什么这样设计 ───────────────────────────────────────
//  画画时手是脏的、视线不该离开画面太久。所以：
//    · 没在计时时：一屏就能看到"预计多少分钟"，一个按钮开始；
//    · 在计时时：**只剩一个大倒计时**和"补过水了"，别的都收起来；
//    · 温湿度用数字表冠调 —— 表上输入数字，表冠比点小键盘现实。
//
//  ── 一个必须说清的限制 ───────────────────────────────────────
//  手表上没有天气（拿城市天气要走网络 + 定位，而且在表上配城市很别扭），
//  所以温湿度是**手调**的，默认 25℃ / 50%。预测值只在这两个数准确时才有意义，
//  界面上把当前用的值一直显示出来，不让用户忘了它是哪来的。
//

import SwiftUI

struct WatchWetnessView: View {

    // ⚠️ 必须用 @Bindable 而不是 let：
    //    `@Observable` 对象只有通过 @Bindable 才能取出 $ 绑定
    //    （温湿度滑块、草稿输入框都要双向绑定）。
    @Bindable var store: WatchWetnessStore

    var body: some View {
        NavigationStack {
            Group {
                if store.session != nil {
                    runningView
                } else {
                    setupView
                }
            }
            .navigationTitle("保湿计时")
        }
    }

    // MARK: - 计时中

    private var runningView: some View {
        ScrollView {
            VStack(spacing: 8) {
                if store.isDue {
                    Text("该补水了")
                        .font(.headline)
                        .foregroundStyle(.orange)
                } else if let remaining = store.secondsRemaining {
                    // ⚠️ 用 Text(timerInterval:) 而不是自己起 Timer：
                    //    系统负责每秒刷新，App 进后台/屏幕常亮都不会停，
                    //    也不用管 Timer 的生命周期（那是最容易漏掉的一类 bug）。
                    Text(timerInterval: Date.now...Date.now.addingTimeInterval(Double(remaining)),
                         countsDown: true)
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text("后需要补水")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let session = store.session {
                    Text(session.usedModel
                         ? "按 \(Int(session.temperatureC))℃ / \(Int(session.relativeHumidity))% 推算"
                         : "固定 \(max(1, Int(session.remistDeadline.timeIntervalSince(session.startedAt) / 60))) 分钟")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }

                if let note = store.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }

                Button {
                    store.remisted()
                } label: {
                    Label("补过水了，重新计时", systemImage: "drop.fill")
                }
                .tint(.blue)

                Button(role: .destructive) {
                    store.stop()
                } label: {
                    Label("结束", systemImage: "stop.fill")
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 开始之前

    private var setupView: some View {
        ScrollView {
            VStack(spacing: 10) {
                predictionCard
                startButton
                quickButtons
                environmentControls
            }
            .padding(.vertical, 2)
        }
    }

    private var predictionCard: some View {
        VStack(spacing: 2) {
            Text("预计 \(store.predictedMinutes) 分钟")
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text("后需要补水")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("\(Int(store.temperatureC))℃ · \(Int(store.relativeHumidity))%")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var startButton: some View {
        Button {
            store.startUsingModel()
        } label: {
            Label("开始计时", systemImage: "play.fill")
        }
        .tint(.green)
    }

    /// 不想管温湿度时的快捷方式。
    private var quickButtons: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("或者直接定")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach([10, 15, 20, 30], id: \.self) { minutes in
                    Button("\(minutes)") {
                        store.startFixed(minutes: minutes)
                    }
                    .font(.caption2)
                }
            }
        }
    }

    /// 温湿度与颜料类型。
    ///
    /// 表冠调温湿度（`digitalCrownRotation`），省得在小键盘上戳数字。
    private var environmentControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("环境")
                .font(.caption2)
                .foregroundStyle(.secondary)

            crownRow(title: "温度",
                     value: $store.temperatureC,
                     range: 5...40, step: 1, unit: "℃")

            crownRow(title: "湿度",
                     value: $store.relativeHumidity,
                     range: 10...95, step: 5, unit: "%")

            Picker("颜料", selection: $store.paintSystem) {
                ForEach(PaintSystem.allCases) { system in
                    Text(system.displayName).tag(system)
                }
            }
            .onChange(of: store.paintSystem) { _, _ in store.saveInputs() }

            Picker("保湿", selection: $store.closure) {
                ForEach(PaletteClosure.allCases) { closure in
                    Text(closure.displayName).tag(closure)
                }
            }
            .onChange(of: store.closure) { _, _ in store.saveInputs() }

            Toggle("到点提醒", isOn: $store.notifyWhenDue)
                .onChange(of: store.notifyWhenDue) { _, _ in store.saveInputs() }
        }
    }

    private func crownRow(title: String,
                          value: Binding<Double>,
                          range: ClosedRange<Double>,
                          step: Double,
                          unit: String) -> some View {
        HStack {
            Text(title)
                .font(.caption2)
            Spacer(minLength: 0)
            Text("\(Int(value.wrappedValue))\(unit)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .focusable()
        .digitalCrownRotation(
            value,
            from: range.lowerBound,
            through: range.upperBound,
            by: step,
            sensitivity: .medium,
            isContinuous: false
        )
        .onChange(of: value.wrappedValue) { _, _ in store.saveInputs() }
    }
}
