//
//  ManualCodeEntryView.swift
//  ArtAssist — 美术生的工具箱
//
//  手动输入编号。三个场景都靠它兜底：
//    · 模拟器没有摄像头
//    · 相机权限被拒
//    · 包装上的条码磨掉了，但编号还看得清
//
//  输入的内容走的是与扫码**完全相同**的解析管线，
//  所以粘贴一段 JSON 也能直接结构化入库。
//

import SwiftUI

struct ManualCodeEntryView: View {

    var onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    private var draft: PaintColorDraft? {
        text.isBlank ? nil : PaintScanParser.parse(payload: text, symbologyRaw: "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如 6901234567892", text: $text, axis: .vertical)
                        .lineLimit(1...5)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .focused($isFocused)
                        .submitLabel(.done)
                        .onSubmit(submit)
                } header: {
                    Text("包装上的编号")
                } footer: {
                    Text("可以直接粘贴二维码里的整段内容。支持 JSON、URL 参数、GS1 条码、键值文本，解析规则与扫码完全一致。")
                }

                if let draft {
                    Section {
                        InfoRow(label: "识别来源", value: draft.source.displayName,
                                symbolName: draft.source.symbolName, tint: .blue)
                        InfoRow(label: "编号", value: draft.code.isBlank ? "（空）" : draft.code,
                                symbolName: "number", tint: Theme.accent)
                        if let name = draft.name {
                            InfoRow(label: "颜色名", value: name, symbolName: "paintpalette")
                        }
                        if let hex = draft.hex {
                            HStack {
                                Text("颜色值").font(.subheadline).foregroundStyle(.secondary)
                                Spacer()
                                Text(hex)
                                    .font(.system(.subheadline, design: .monospaced))
                                ColorDot(hex: hex, size: 18)
                            }
                        }
                        ForEach(draft.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    } header: {
                        Text("解析预览")
                    } footer: {
                        Text(draft.qualitySummary)
                    }
                }

                Section {
                    Button {
                        text = samplePayload
                    } label: {
                        Label("填入一段示例 JSON", systemImage: "wand.and.stars")
                    }
                    .font(.subheadline)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("手动输入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("识别") { submit() }
                        .disabled(text.isBlank)
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { isFocused = true }
    }

    private var samplePayload: String {
        """
        {"code":"6901234567892","name":"群青","brand":"马利","series":"艺术家级","hex":"#2E5BFF"}
        """
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        dismiss()
    }
}
