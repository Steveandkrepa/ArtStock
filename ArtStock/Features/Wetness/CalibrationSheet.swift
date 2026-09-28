//
//  CalibrationSheet.swift
//  ArtAssist — 美术生的工具箱
//
//  实测校准：用一次真实观测，反推出属于你的常数 K。
//
//  ── 为什么必须做这一步 ────────────────────────────────────────
//  模型里的 K 由"颜料体系 + 膜厚 + 容器密闭程度 + 通风"共同决定，
//  这些输入 App 一个都拿不到。所以默认值只能是起点猜测。
//  唯一能让预测变准的办法，就是你实测一次：
//      从开始计时到"真的该补水了"，实际过了多久。
//  然后 K = 实测时长 × VPD ÷ 容器倍数 ÷ 补水比例。
//
//  拆掉这个步骤，模型就只是个好看的公式。
//

import SwiftUI

struct CalibrationSheet: View {

    let paintSystem: PaintSystem
    let closure: PaletteClosure
    let temperatureC: Double
    let relativeHumidity: Double

    @Environment(\.dismiss) private var dismiss

    /// 实测时长（小时）。支持小数，比如 2.5 小时。
    @State private var hoursText: String = ""

    private var hours: Double? {
        let cleaned = hoursText.trimmed.replacingOccurrences(of: "，", with: ".")
        guard let value = Double(cleaned), value > 0 else { return nil }
        return value
    }

    private var derivedCalibration: Double? {
        guard let hours else { return nil }
        return DryingModel.calibrate(
            observedHours: hours,
            temperatureC: temperatureC,
            relativeHumidity: relativeHumidity,
            closure: closure
        )
    }

    private var currentCalibration: Double? {
        WetnessPreferences.calibration(for: paintSystem)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("回忆一次真实的经历：你从开始观察这盘颜料，到觉得「该喷水了」，一共过了多久？")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("怎么校准")
                }

                Section {
                    HStack {
                        TextField("例如 8", text: $hoursText)
                            .keyboardType(.decimalPad)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 100)
                        Text("小时")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("实测时长")
                } footer: {
                    Text("不用很精确，差半小时没关系。真正影响结果的是「你判定的干湿程度」要和你以后用的一致。")
                }

                Section {
                    InfoRow(label: "颜料", value: paintSystem.displayName, symbolName: paintSystem.symbolName)
                    InfoRow(label: "放置方式", value: closure.displayName, symbolName: closure.symbolName)
                    InfoRow(label: "温湿度",
                            value: "\(Fmt.number(temperatureC, maximumFractionDigits: 1))℃ / \(Int(relativeHumidity.rounded()))%",
                            symbolName: "thermometer.medium")
                    InfoRow(label: "水汽压差",
                            value: String(format: "%.2f kPa", DryingModel.vaporPressureDeficit(
                                temperatureC: temperatureC, relativeHumidity: relativeHumidity)),
                            symbolName: "wind")
                } header: {
                    Text("这次校准用的条件")
                } footer: {
                    Text("温湿度取的是当前值，条件差太多会偏。尽量挑天气相近的时候校准。")
                }

                Section {
                    if let derived = derivedCalibration {
                        HStack {
                            Text("推算出 K")
                            Spacer()
                            Text(String(format: "%.1f", derived))
                                .font(.system(.title3, design: .rounded).weight(.semibold))
                                .foregroundStyle(.green)
                                .monospacedDigit()
                        }
                        if let current = currentCalibration {
                            HStack {
                                Text("原来用的 K")
                                Spacer()
                                Text(String(format: "%.1f", current))
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            let ratio = current > 0 ? derived / current : 0
                            Text(ratio > 1
                                 ? "新常数比原来大 \(Fmt.number(ratio, maximumFractionDigits: 1)) 倍 —— 说明你的颜料比默认值更耐久。"
                                 : "新常数比原来小 \(Fmt.number(1 / max(ratio, 0.01), maximumFractionDigits: 1)) 倍 —— 说明它比默认值干得更快。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if hours != nil {
                        Label("这个时长算出来的常数不合理，请核对一下。", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text("填上时长后这里会显示推算结果。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } header: {
                    Text("结果")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("实测校准")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let derived = derivedCalibration {
                            WetnessPreferences.setCalibration(derived, for: paintSystem)
                            Haptics.saved()
                        }
                        dismiss()
                    }
                    .disabled(derivedCalibration == nil)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
