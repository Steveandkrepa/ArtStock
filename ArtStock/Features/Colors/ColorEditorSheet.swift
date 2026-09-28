//
//  ColorEditorSheet.swift
//  ArtAssist — 美术生的工具箱
//
//  改一个颜色的资料：色名、色值、品牌、系列、颜料标准号、备注。
//
//  为什么必须有这个界面：预设的 42 个色值是"通行的代表性色值"，
//  不是你那盒颜料在屏幕上该有的样子。屏幕显色、品牌差异、个体差异
//  三者叠加，任何一份内置色卡都一定有人觉得不像。
//  与其争论谁的色值对，不如让人自己改 —— 你的颜料你自己最清楚。
//

import SwiftData
import SwiftUI

struct ColorEditorSheet: View {

    let color: PaintColor

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var hex = "#2E5BFF"
    @State private var brand = ""
    @State private var series = ""
    @State private var ciCode = ""
    @State private var notes = ""
    @State private var didLoad = false
    @State private var isConfirmingDelete = false

    /// 这个颜色在盒子里占了几格 —— 删之前要让用户知道会影响到什么。
    private var wellCount: Int { color.wells.count }

    private var trimmedName: String { name.trimmed }

    private var canSave: Bool { !trimmedName.isEmpty }

    /// 色号是业务主键，PRESET-xx 表示它是预设色。
    private var isPreset: Bool { color.code.hasPrefix("PRESET-") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    previewCard
                    basicCard
                    standardCard
                    noteCard
                    if !isPreset { dangerCard }
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .artScrollEdgeEffect()
            .navigationTitle("编辑颜色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear(perform: load)
        .alert("删除这个颜色？", isPresented: $isConfirmingDelete) {
            Button("删除", role: .destructive) { deleteColor() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(wellCount > 0
                 ? "盒子里有 \(wellCount) 格装着它，删掉之后这些格子会变成空格（颜色不会自动换）。"
                 : "颜色库里会少这一条。")
        }
    }

    // MARK: - 预览

    private var previewCard: some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: hex) ?? Theme.emptyWellFill)
                .frame(width: 88, height: 88)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(trimmedName.isEmpty ? "未命名" : trimmedName)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(hex.uppercased())
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if !ciCode.trimmed.isEmpty {
                    Text(ciCode.trimmed.uppercased())
                        .font(.system(.caption2, design: .monospaced).weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.15), in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
            }

            Spacer(minLength: 0)
        }
        .cardStyle()
    }

    // MARK: - 基本信息

    private var basicCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "基本信息")

            LabeledContent("颜色名") {
                TextField("如「群青」", text: $name)
                    .multilineTextAlignment(.trailing)
            }

            LabeledContent("色值") {
                HStack(spacing: 10) {
                    TextField("#RRGGBB", text: $hex)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                    ColorPicker("", selection: Binding(
                        get: { Color(hex: hex) ?? .blue },
                        set: { hex = $0.toHex() ?? hex }
                    ), supportsOpacity: false)
                    .labelsHidden()
                }
            }

            LabeledContent("品牌") {
                TextField("如「马利」", text: $brand)
                    .multilineTextAlignment(.trailing)
            }

            LabeledContent("系列 / 等级") {
                TextField("如「学生级」", text: $series)
                    .multilineTextAlignment(.trailing)
            }

            Text("色号 \(color.code)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - 颜料标准

    private var standardCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "颜料标准号", subtitle: "选填")

            TextField("如 PW6、PB29、PR108", text: $ciCode)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .textFieldStyle(.plain)

            Text("Colour Index 国际颜料编号，规定的是化学成分（PW6 就是钛白）。"
                 + "颜料没有 RGB 的国际标准，同一个 PB29 各家色相也不同 —— 不像就自己调。")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - 备注

    private var noteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "备注")
            TextField("比如「这支偏冷，调肤色少放」", text: $notes, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - 删除

    private var dangerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("从颜色库删除", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .artGlassButton()

            Text("预设的 42 色不能删 —— 删了「载入预设」会再建回来，只会让人困惑。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - 读写

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        name = color.name
        hex = color.hex.isBlank ? "#2E5BFF" : color.hex
        brand = color.brand
        series = color.series
        ciCode = color.ciCode ?? ""
        notes = color.notes
    }

    private func save() {
        color.name = trimmedName
        if let normalized = Self.normalizeHex(hex) { color.hex = normalized }
        color.brand = brand.trimmed
        color.series = series.trimmed
        color.ciCode = ciCode.trimmed.uppercased().nilIfBlank
        color.notes = notes
        color.updatedAt = .now
        try? context.save()
        Haptics.saved()
        dismiss()
    }

    private func deleteColor() {
        PaletteService.delete(color, in: context)
        Haptics.selection()
        dismiss()
    }

    /// 把用户输入的色值收敛成 `#RRGGBB`；实在认不出来就返回 nil（保留原值）。
    static func normalizeHex(_ raw: String) -> String? {
        var text = raw.trimmed.uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        // 支持 8 位带 alpha 的写法，丢掉 alpha。
        if text.count == 8 { text = String(text.prefix(6)) }
        // 支持 #ABC 简写。
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6 else { return nil }
        guard text.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + text
    }
}
