//
//  DXArtAPISettingsView.swift
//  ArtAssist — 美术生的工具箱
//
//  接口设置：域名、客户端版本号、取页宽度。
//
//  ── 为什么要把这些露出来 ─────────────────────────────────────
//  这些值是从厂家客户端里逆向出来的，写死在代码里。
//  厂家一升级 App，`version` 头或 `appVersion` 参数就可能失效，
//  接口立刻全挂。
//
//  如果只能改代码、重新打包、再自签名安装一遍 —— 对用户来说是
//  "这个功能突然就坏了，而且没法自己修"。
//  露出来之后，至少能自己试出正确的版本号。
//
//  这是我在这个功能里**唯一**加的自由度：接口路径、参数名、请求头
//  一律不许改（那是契约，改了就真错了）。只有版本号这类会被厂家
//  单方面提升的值允许覆盖。
//

import SwiftUI

struct DXArtAPISettingsView: View {

    @Bindable var session: DXArtSession

    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var apiVersion = ""
    @State private var appVersion = ""
    @State private var equipmentType = ""
    @State private var level3Width = 1230
    @State private var searchPageSize = 50
    @State private var isConfirmingReset = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("域名", text: $host)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("服务器")
                } footer: {
                    Text("不带协议时自动补 https://。")
                }

                Section {
                    TextField("version 请求头", text: $apiVersion)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    TextField("appVersion 参数", text: $appVersion)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                    TextField("equipmentType", text: $equipmentType)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("客户端版本号")
                } footer: {
                    Text("厂家升级 App 后接口可能只认新版本号。如果搜索/取页突然报错，"
                         + "把这里改成和商店里最新版一致的数字试试。")
                }

                Section {
                    Stepper("取页宽度 \(level3Width)", value: $level3Width, in: 600...3000, step: 50)
                    Stepper("搜索每页 \(searchPageSize) 条", value: $searchPageSize, in: 10...50, step: 10)
                } header: {
                    Text("取页参数")
                } footer: {
                    Text("宽度越大图越清晰、文件越大。原来的脚本用的是 1230。")
                }

                Section {
                    Button {
                        save()
                    } label: {
                        Label("保存", systemImage: "checkmark")
                    }

                    Button {
                        isConfirmingReset = true
                    } label: {
                        Label("恢复默认", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(!session.config.isCustomized)
                }

                Section {
                    LabeledContent("当前域名", value: session.config.host)
                        .font(.caption)
                    LabeledContent("是否已自定义",
                                   value: session.config.isCustomized ? "是" : "否")
                        .font(.caption)
                } header: {
                    Text("当前状态")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("接口设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("提示", isPresented: .presentWhen($message)) {
                Button("好") { message = nil; dismiss() }
            } message: {
                Text(message ?? "")
            }
            .confirmationDialog("恢复默认接口设置？", isPresented: $isConfirmingReset, titleVisibility: .visible) {
                Button("恢复默认", role: .destructive) {
                    DXArtConfig.resetToStandard()
                    session.config = .standard
                    load()
                    message = "已恢复成脚本里实测能跑通的那组值。"
                }
                Button("取消", role: .cancel) {}
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        let config = session.config
        host = config.host
        apiVersion = config.apiVersion
        appVersion = config.appVersion
        equipmentType = config.equipmentType
        level3Width = config.level3Width
        searchPageSize = config.searchPageSize
    }

    private func save() {
        var updated = session.config
        updated.host = DXArtConfig.normalizeHost(host)
        updated.apiVersion = apiVersion.trimmed.isEmpty
            ? DXArtConfig.standard.apiVersion : apiVersion.trimmed
        updated.appVersion = appVersion.trimmed.isEmpty
            ? DXArtConfig.standard.appVersion : appVersion.trimmed
        updated.equipmentType = equipmentType.trimmed.isEmpty
            ? DXArtConfig.standard.equipmentType : equipmentType.trimmed
        updated.level3Width = level3Width
        updated.searchPageSize = searchPageSize
        session.config = updated

        Haptics.saved()
        message = "接口设置已保存。改错了可以点「恢复默认」回到原脚本那组值。"
    }
}
