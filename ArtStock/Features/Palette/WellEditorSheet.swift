//
//  WellEditorSheet.swift
//  ArtAssist — 美术生的工具箱
//
//  点开一格之后做的事：改余量、换颜色、补充。
//
//  这是全 App 最高频的交互 —— 站在画桌前随手点一下。
//  所以余量用**五个大按钮**而不是滑块或步进器：点一下就完事，
//  不需要瞄准，也不需要读数字。
//

import SwiftData
import SwiftUI

struct WellEditorSheet: View {

    let well: PaletteWell

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var isShowingColorPicker = false
    @State private var isEditingColor = false
    @State private var lastOutcome: RefillOutcome?

    private var color: PaintColor? { well.color }

    private var stockSummary: String? {
        guard let color, !color.refills.isEmpty else { return nil }
        let parts = color.refills
            .sorted { $0.kind == .squeeze && $1.kind != .squeeze }
            .map { "\($0.kind.shortName) \($0.capacityDescription)" }
        return parts.joined(separator: " ｜ ")
    }

    /// 这一格对应的颜色是否还有任何可用库存。
    private var hasUsableStock: Bool {
        guard let color else { return false }
        return color.refills.contains { $0.refillCapacity > 0 }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    levelPicker
                    if color != nil { refillCard }
                    colorCard
                    noteCard
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .artScrollEdgeEffect()
            .navigationTitle("第 \(well.positionLabel) 格")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $isShowingColorPicker) {
            ColorPickerSheet(current: color) { picked in
                PaletteService.assign(picked, to: well, in: context)
                Haptics.saved()
            }
        }
        .sheet(isPresented: $isEditingColor) {
            if let color {
                ColorEditorSheet(color: color)
            }
        }
        .alert("补充结果", isPresented: .presentWhen($lastOutcome)) {
            Button("好") { lastOutcome = nil }
        } message: {
            Text(lastOutcome?.message ?? "")
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(hex: color?.hex ?? "") ?? Theme.emptyWellFill)
                if color == nil {
                    Image(systemName: "plus")
                        .font(.title2)
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                }
            }
            .frame(width: 84, height: 84)

            VStack(alignment: .leading, spacing: 6) {
                Text(color?.name ?? "空格子")
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if let color {
                    if !color.detailLine.isBlank {
                        Text(color.detailLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(color.code)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                WellLevelBadge(level: well.level)
            }

            Spacer(minLength: 0)
        }
        .cardStyle()
    }

    // MARK: - 余量选择

    private var levelPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "还剩多少", subtitle: "点一下就行")

            // 五个大按钮，占满整行，不需要瞄准
            HStack(spacing: 8) {
                ForEach(WellLevel.allCases.reversed(), id: \.self) { level in
                    Button {
                        PaletteService.setLevel(level, for: well, in: context)
                        Haptics.selection()
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .strokeBorder(Theme.color(for: level), lineWidth: 2)
                                    .frame(width: 30, height: 30)
                                Circle()
                                    .fill(Theme.color(for: level))
                                    .frame(width: 30 * level.fill, height: 30 * level.fill)
                            }
                            Text(level.displayName)
                                .font(.caption2)
                                .foregroundStyle(well.level == level ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            well.level == level ? Theme.tint(for: level) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("设为\(level.displayName)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - 补充

    private var refillCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "补充装库存",
                          subtitle: well.color == nil ? "先给这一格选个颜色" : "两种补充装可以同时有")

            if let color = well.color {
                // ── 两种补充装直接在这里改 ──
                //
                // 之前这一步被放在「库存与采购」分区里：用户得离开颜料盒、
                // 在 42 个颜色里翻出同一个颜色、再点进去改。管理被割裂成两处，
                // 而实际场景是"我正看着这一格，发现它快空了，顺手记一下我还有几支"。
                ForEach(RefillKind.allCases) { kind in
                    refillRow(kind: kind, color: color)
                }

                Divider()

                if well.level.needsRefill {
                    Button {
                        if let outcome = PaletteService.refillAll(for: color, in: context) {
                            lastOutcome = outcome
                            Haptics.saved()
                        } else {
                            lastOutcome = RefillOutcome(wellsFilled: 0, unitsUsed: 0,
                                                        remainingCapacity: 0, wasShort: true)
                        }
                    } label: {
                        Label("用库存补满这一格", systemImage: "arrow.up.to.line")
                            .frame(maxWidth: .infinity)
                    }
                    .artProminentButton()
                    .controlSize(.large)
                    .disabled(!hasUsableStock)

                    if !hasUsableStock {
                        Text("这个颜色的两种补充装都没有了，先在上面填上你有多少。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    HStack(spacing: 10) {
                        Label("这一格还够用", systemImage: "checkmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("我刚补过了") {
                            PaletteService.markRefilled(well, in: context)
                            Haptics.saved()
                        }
                        .font(.subheadline)
                        .buttonStyle(.borderless)
                    }
                }
            } else {
                Text("这一格还没装颜色，所以没有对应的补充装库存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    /// 单种补充装的一行：还有几件 +（挤出装）每件补几格。
    @ViewBuilder
    private func refillRow(kind: RefillKind, color: PaintColor) -> some View {
        let stock = color.refills.first { $0.kind == kind }

        VStack(alignment: .leading, spacing: 6) {
            Stepper(value: unitsBinding(kind: kind, color: color), in: 0...999) {
                HStack(spacing: 8) {
                    Image(systemName: kind.symbolName)
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                    Text(kind.displayName)
                        .font(.subheadline)
                    Spacer()
                    Text("\(stock?.units ?? 0) \(kind.unitName)")
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }

            if kind.capacityIsUserDefined {
                Stepper(value: capacityBinding(kind: kind, color: color), in: 1...20) {
                    HStack(spacing: 8) {
                        Text("每件能补几格")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 22)
                        Spacer()
                        Text("\(stock?.capacityPerUnit ?? kind.defaultCapacityPerUnit) 格")
                            .font(.caption)
                            .monospacedDigit()
                    }
                }
            }

            if let stock, stock.units > 0 || stock.partialCapacity > 0 {
                Text(stock.capacityDescription)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 22)
            }
        }
    }

    // MARK: - 库存绑定

    private func unitsBinding(kind: RefillKind, color: PaintColor) -> Binding<Int> {
        Binding(
            get: { color.refills.first { $0.kind == kind }?.units ?? 0 },
            set: { newValue in
                let existing = color.refills.first { $0.kind == kind }
                PaletteService.setStock(
                    units: newValue,
                    capacityPerUnit: existing?.capacityPerUnit ?? kind.defaultCapacityPerUnit,
                    partialCapacity: existing?.partialCapacity ?? 0,
                    kind: kind, for: color, in: context
                )
                Haptics.selection()
            }
        )
    }

    private func capacityBinding(kind: RefillKind, color: PaintColor) -> Binding<Int> {
        Binding(
            get: { color.refills.first { $0.kind == kind }?.capacityPerUnit ?? kind.defaultCapacityPerUnit },
            set: { newValue in
                let existing = color.refills.first { $0.kind == kind }
                PaletteService.setStock(
                    units: existing?.units ?? 0,
                    capacityPerUnit: newValue,
                    partialCapacity: existing?.partialCapacity ?? 0,
                    kind: kind, for: color, in: context
                )
            }
        )
    }

    // MARK: - 颜色

    private var colorCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "这一格装的什么")

            Button {
                isShowingColorPicker = true
            } label: {
                HStack {
                    if let color {
                        ColorDot(hex: color.hex)
                        Text(color.name)
                    } else {
                        Image(systemName: "paintpalette")
                        Text("选择颜色")
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .artGlassButton()

            if color != nil {
                HStack(spacing: 16) {
                    Button {
                        isEditingColor = true
                    } label: {
                        Label("色值不像？改它", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderless)

                    Button(role: .destructive) {
                        PaletteService.assign(nil, to: well, in: context)
                        Haptics.selection()
                    } label: {
                        Label("清空这一格", systemImage: "eraser")
                    }
                    .buttonStyle(.borderless)
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - 备注

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "备注")
            TextField("比如「这块有点干，下次多加点水」", text: Binding(
                get: { well.note },
                set: { well.note = $0; try? context.save() }
            ), axis: .vertical)
            .lineLimit(2...4)
            .textFieldStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// MARK: - 颜色选择

/// 从颜色库里挑一个装进格子；也可以现场新建。
struct ColorPickerSheet: View {

    let current: PaintColor?
    var onPick: (PaintColor) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \PaintColor.name) private var colors: [PaintColor]

    @State private var searchText = ""
    @State private var newColorName = ""
    @State private var newColorHex = "#2E5BFF"

    private var filtered: [PaintColor] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return colors }
        return colors.filter {
            $0.name.lowercased().contains(needle)
                || $0.code.lowercased().contains(needle)
                || $0.brand.lowercased().contains(needle)
                || ($0.ciCode ?? "").lowercased().contains(needle)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        ColorPicker("", selection: Binding(
                            get: { Color(hex: newColorHex) ?? .blue },
                            set: { newColorHex = $0.toHex() ?? newColorHex }
                        ), supportsOpacity: false)
                        .labelsHidden()

                        TextField("颜色名，如「群青」", text: $newColorName)

                        Button {
                            createAndPick()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                        .disabled(newColorName.isBlank)
                    }
                } header: {
                    Text("新建颜色")
                } footer: {
                    Text("扫码入库的颜色也会出现在下面这个列表里。")
                }

                if colors.isEmpty {
                    Section {
                        Text("颜色库还是空的。扫一支颜料的包装，或者在上面直接新建一个。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("颜色库（\(filtered.count)）") {
                        ForEach(filtered) { color in
                            Button {
                                onPick(color)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    ColorDot(hex: color.hex, size: 26)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(color.name)
                                            .foregroundStyle(.primary)
                                        if !color.detailLine.isBlank {
                                            Text(color.detailLine)
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if current?.code == color.code {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Theme.accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "搜颜色名或色号")
            .navigationTitle("选择颜色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func createAndPick() {
        // 现场新建的颜色用一个本地色号（时间戳），保证唯一且能追溯。
        let code = "MINE-\(Int(Date.now.timeIntervalSince1970))"
        let created = PaletteService.upsertColor(
            code: code,
            name: newColorName.trimmed,
            hex: newColorHex,
            in: context
        )
        Haptics.saved()
        onPick(created)
        dismiss()
    }
}
