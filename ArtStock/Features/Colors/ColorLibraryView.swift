//
//  ColorLibraryView.swift
//  ArtAssist — 美术生的工具箱
//
//  颜色库：一盒 42 格 + 扫码/自己建的颜色，全都在这儿。
//
//  这个分区只干一件事：**校正颜色本身**。
//  跟「库存与采购」的分工是清楚的 ——
//    · 颜色库 = 这个颜色长什么样、叫什么、是哪个颜料标准号
//    · 库存与采购 = 它还剩几支、该不该买
//
//  为什么要单开一页：内置色值再准也一定有人觉得不像。
//  屏幕显色、品牌差异、个体差异叠在一起，没有任何一份内置色卡能让所有人满意。
//  所以色值必须是可改的，而不是写死在代码里让你忍。
//

import SwiftData
import SwiftUI

struct ColorLibraryView: View {

    @Environment(\.modelContext) private var context

    @Query(sort: \PaintColor.name) private var colors: [PaintColor]

    @State private var searchText = ""
    @State private var editing: PaintColor?
    @State private var isCreating = false
    @State private var isCalibrating = false
    @State private var refreshMessage: String?

    private var filtered: [PaintColor] {
        let needle = searchText.trimmed.lowercased()
        guard !needle.isEmpty else { return colors }
        return colors.filter {
            $0.name.lowercased().contains(needle)
                || $0.code.lowercased().contains(needle)
                || $0.brand.lowercased().contains(needle)
                || ($0.ciCode ?? "").lowercased().contains(needle)
                || $0.hex.lowercased().contains(needle)
        }
    }

    /// 预设 42 色单独成组 —— 它们的色值来自标准数据，跟手建的颜色性质不同。
    private var presetColors: [PaintColor] {
        filtered.filter { $0.code.hasPrefix("PRESET-") }
            .sorted { $0.code < $1.code }
    }

    private var otherColors: [PaintColor] {
        filtered.filter { !$0.code.hasPrefix("PRESET-") }
    }

    /// 颜色库里有多少条缺颜料标准号 —— 顺手提示一下还能补什么。
    private var missingCICount: Int {
        colors.filter { $0.ciCode?.isBlank ?? true }.count
    }

    /// 已经从实物采过色的条数。
    private var calibratedCount: Int {
        colors.filter(\.isCalibrated).count
    }

    var body: some View {
        List {
            if !colors.isEmpty, calibratedCount == 0 {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("这些色值是照色名推断的，不一定像你的实物", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.orange)
                        Text("色值取自厂家色卡，实物仍可能有差别。可以对着打开的颜料盒采一遍。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            isCalibrating = true
                        } label: {
                            Label("取色校准", systemImage: "camera.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .artProminentButton()
                    }
                    .padding(.vertical, 4)
                }
            }

            if colors.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                if !presetColors.isEmpty {
                    Section {
                        ForEach(presetColors) { row($0) }
                    } header: {
                        Text("42 色预设（\(presetColors.count)）")
                    } footer: {
                        Text("色值取自厂家色卡。觉得不像就点进去改。")
                    }
                }

                if !otherColors.isEmpty {
                    Section("其他颜色（\(otherColors.count)）") {
                        ForEach(otherColors) { row($0) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "搜色名、色号、品牌或颜料标准号")
        .navigationTitle("颜色库")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        isCalibrating = true
                    } label: {
                        Label("取色校准（从实物上采色）", systemImage: "camera.viewfinder")
                    }

                    Button {
                        isCreating = true
                    } label: {
                        Label("新建颜色", systemImage: "plus")
                    }

                    Button {
                        refreshFromStandard()
                    } label: {
                        Label("把预设色值刷成标准值", systemImage: "arrow.triangle.2.circlepath")
                    }

                    if missingCICount > 0 {
                        Button {
                            refreshFromStandard()
                        } label: {
                            Label("补全缺失的颜料标准号（\(missingCICount)）", systemImage: "number")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $editing) { color in
            ColorEditorSheet(color: color)
        }
        .fullScreenCover(isPresented: $isCalibrating) {
            ColorCalibrationView()
        }
        .sheet(isPresented: $isCreating) {
            ColorCreatorSheet { created in
                // 等创建面板收完再弹编辑面板 —— 同时呈现两个 sheet 会被系统丢掉一个。
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    editing = created
                }
            }
        }
        .alert("已刷新", isPresented: .presentWhen($refreshMessage)) {
            Button("好") { refreshMessage = nil }
        } message: {
            Text(refreshMessage ?? "")
        }
    }

    // MARK: - 一行

    private func row(_ color: PaintColor) -> some View {
        Button {
            editing = color
        } label: {
            HStack(spacing: 14) {
                ColorDot(hex: color.hex, size: 34)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(color.name)
                            .foregroundStyle(.primary)
                        if color.isCalibrated {
                            Text("已校准")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.green.opacity(0.16), in: Capsule())
                                .foregroundStyle(.green)
                        }
                        if let ci = color.ciCode, !ci.isBlank {
                            Text(ci)
                                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.14), in: Capsule())
                                .foregroundStyle(Theme.accent)
                        }
                    }

                    HStack(spacing: 6) {
                        Text(color.hex.uppercased())
                            .font(.system(.caption2, design: .monospaced))
                        if !color.subtitle.isBlank {
                            Text("·")
                            Text(color.subtitle)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if color.wells.count > 0 {
                    Text("\(color.wells.count) 格")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 空状态

    private var emptyState: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Label("颜色库还是空的", systemImage: "paintpalette")
                    .font(.headline)
                Text("在「颜料盒」里点右上角菜单载入 42 色预设，或者扫一支颜料的包装入库。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    loadPresetNow()
                } label: {
                    Label("载入 42 色预设", systemImage: "square.grid.3x3.fill")
                        .frame(maxWidth: .infinity)
                }
                .artProminentButton()
            }
            .padding(.vertical, 8)
        }
    }

    // MARK: - 动作

    private func loadPresetNow() {
        let box = PaletteService.loadOrCreateBox(in: context)
        let result = PaletteService.loadPresetColors(into: box, overwrite: false, in: context)
        Haptics.saved()
        refreshMessage = "新建 \(result.colorsCreated) 个颜色，填进 \(result.wellsFilled) 格。"
    }

    private func refreshFromStandard() {
        let updated = PaletteService.refreshPresetColors(in: context)
        Haptics.saved()
        refreshMessage = updated == 0
            ? "预设色值已经是最新的标准数据了。"
            : "刷新了 \(updated) 个预设色的标准色值与颜料标准号。"
              + "你自己建的颜色、改过名的颜色、以及取色校准过的颜色都没有被动。"
    }
}

// MARK: - 新建颜色

/// 手建一个颜色。扫码入库是另一条路，这里管"库里没有、我也不想扫"的情况。
private struct ColorCreatorSheet: View {

    var onCreated: (PaintColor) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var hex = "#2E5BFF"
    @State private var brand = ""
    @State private var series = ""
    @State private var ciCode = ""

    private var trimmedName: String { name.trimmed }

    var body: some View {
        NavigationStack {
            Form {
                Section("颜色") {
                    HStack(spacing: 14) {
                        ColorPicker("", selection: Binding(
                            get: { Color(hex: hex) ?? .blue },
                            set: { hex = $0.toHex() ?? hex }
                        ), supportsOpacity: false)
                        .labelsHidden()

                        TextField("颜色名，如「群青」", text: $name)

                        Text(hex.uppercased())
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    TextField("品牌，如「马利」", text: $brand)
                    TextField("系列 / 等级，如「学生级」", text: $series)
                    TextField("颜料标准号，如 PW6", text: $ciCode)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                } header: {
                    Text("选填")
                } footer: {
                    Text("Colour Index 国际编号（PW6 = 钛白），填了也能按它搜。")
                }
            }
            .navigationTitle("新建颜色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { create() }
                        .disabled(trimmedName.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func create() {
        // 手建颜色用时间戳做色号，保证唯一且能追溯到"这是我自己加的"。
        let code = "MINE-\(Int(Date.now.timeIntervalSince1970))"
        let created = PaletteService.upsertColor(
            code: code,
            name: trimmedName,
            brand: brand.trimmed,
            series: series.trimmed,
            hex: ColorEditorSheet.normalizeHex(hex) ?? hex,
            ciCode: ciCode.trimmed.uppercased().nilIfBlank,
            in: context
        )
        Haptics.saved()
        dismiss()
        onCreated(created)
    }
}
