//
//  DXArtLoginView.swift
//  ArtAssist — 美术生的工具箱
//
//  教材平台的登录：手机号 + 短信验证码。
//
//  ── 和原 Python 脚本的区别 ───────────────────────────────────
//  原脚本用 `questionary.text()` 在终端里问手机号和验证码，
//  还会把 token 明文写进 `dxart_token.txt`。
//
//  这里：
//    · 正常的两步表单，手机号会记住（下次不用重敲）
//    · 验证码有 60 秒重发倒计时（原脚本没有，用户会连点数次，
//      然后收到好几条短信）
//    · token 进 Keychain（见 Keychain.swift）
//    · 错误直接显示接口的原话，不吞掉
//

import SwiftUI

struct DXArtLoginView: View {

    @Bindable var session: DXArtSession
    var onSuccess: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var phone = ""
    @State private var code = ""
    @State private var step: Step = .phone
    @State private var errorText: String?
    @State private var isWorking = false
    @State private var countdown = 0
    @State private var countdownTask: Task<Void, Never>?
    @State private var isShowingAPISettings = false

    enum Step { case phone, code }

    private var canSendCode: Bool {
        phone.trimmingCharacters(in: .whitespaces).count >= 6 && countdown == 0 && !isWorking
    }

    private var canVerify: Bool {
        !code.trimmingCharacters(in: .whitespaces).isEmpty && !isWorking
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    introCard
                    formCard
                    if let errorText {
                        NoticeBanner(level: .error, title: "登录失败", message: errorText)
                    }
                    footerCard
                }
                .padding(20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .artScrollEdgeEffect()
            .navigationTitle("登录教材平台")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingAPISettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("接口设置")
                }
            }
            .sheet(isPresented: $isShowingAPISettings) {
                DXArtAPISettingsView(session: session)
            }
            .onAppear {
                phone = session.savedPhone
                if !phone.isEmpty { step = .code }
            }
            .onDisappear { countdownTask?.cancel() }
        }
    }

    // MARK: - 说明

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("为什么需要登录", systemImage: "person.badge.key")
                .font(.headline)

            Text("""
            教材是付费内容，接口要带上你账号的凭证才能搜索与取页。
            登录用的是**你自己的手机号**，验证码由平台发给你。

            凭证只保存在本机的 Keychain 里（不是明文文件，也不进备份），
            随时可以在设置里退出登录清掉。
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - 表单

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(
                title: step == .phone ? "第 1 步：手机号" : "第 2 步：验证码",
                subtitle: step == .phone ? "用来接收短信验证码" : "已经发到 \(phone)"
            )

            HStack(spacing: 10) {
                TextField("手机号", text: $phone)
                    .keyboardType(.numberPad)
                    .textContentType(.telephoneNumber)
                    .font(.system(.body, design: .monospaced))
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .disabled(isWorking)

                if step == .code {
                    Button("改号") {
                        step = .phone
                        code = ""
                        countdownTask?.cancel()
                        countdown = 0
                    }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                }
            }

            if step == .phone {
                Button {
                    Task { await sendCode() }
                } label: {
                    HStack {
                        if isWorking { ProgressView().tint(.white) }
                        Text(countdown > 0 ? "\(countdown) 秒后可重发" : "发送验证码")
                    }
                    .frame(maxWidth: .infinity)
                }
                .artProminentButton()
                .controlSize(.large)
                .disabled(!canSendCode)
            } else {
                TextField("6 位验证码", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(.title3, design: .monospaced))
                    .padding(.vertical, 12)
                    .padding(.horizontal, 12)
                    .background(Color(uiColor: .secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .disabled(isWorking)

                HStack(spacing: 12) {
                    Button {
                        Task { await verify() }
                    } label: {
                        HStack {
                            if isWorking { ProgressView().tint(.white) }
                            Text("登录")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .artProminentButton()
                    .controlSize(.large)
                    .disabled(!canVerify)

                    Button(countdown > 0 ? "\(countdown)s" : "重发") {
                        Task { await sendCode() }
                    }
                    .artGlassButton()
                    .controlSize(.large)
                    .disabled(countdown > 0 || isWorking)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var footerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("接口地址：\(session.config.host)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            if session.config.isCustomized {
                Label("已自定义接口设置", systemImage: "wrench.and.screwdriver")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 动作

    private func sendCode() async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            try await session.sendCode(phone: phone)
            step = .code
            startCountdown()
            Haptics.saved()
        } catch {
            errorText = error.localizedDescription
            Haptics.alert()
        }
    }

    private func verify() async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            try await session.verify(phone: phone, code: code)
            Haptics.saved()
            onSuccess()
            dismiss()
        } catch {
            errorText = error.localizedDescription
            Haptics.alert()
        }
    }

    /// 60 秒重发倒计时。原脚本没有这个 —— 用户会连点，
    /// 然后一次收到好几条短信，还可能触发平台的频率限制。
    private func startCountdown() {
        countdownTask?.cancel()
        countdown = 60
        countdownTask = Task {
            while countdown > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                countdown -= 1
            }
        }
    }
}
