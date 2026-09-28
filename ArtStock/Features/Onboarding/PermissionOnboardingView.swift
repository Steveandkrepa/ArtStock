//
//  PermissionOnboardingView.swift
//  ArtAssist — 美术生的工具箱
//
//  首次启动的权限引导。
//
//  为什么要有这一页：权限弹窗本来就应该在**首次打开时**出现，
//  跟其他 App 一样。把它藏到"用户点进扫码页"之后再问，既不符合习惯，
//  也容易因为视图层级问题根本问不出来。
//
//  而且先说清楚用途再弹窗，同意率会高得多 —— 系统弹窗本身只有一句话，
//  用户不知道"为什么"就容易点拒绝，而拒绝之后要再去设置里开就很麻烦。
//

import SwiftUI

struct PermissionOnboardingView: View {

    let coordinator: PermissionCoordinator
    var onFinish: () -> Void

    @State private var step: Int = 0

    private let pages: [(symbol: String, title: String, body: String, note: String)] = [
        (
            "paintpalette.fill",
            "欢迎使用 ArtAssist",
            "管好一盒 42 格颜料：哪几格快见底、补充装还够不够、该不该买。",
            "数据只存在本机。联网只在你主动查天气、搜教材时发生。"
        ),
        (
            "camera.fill",
            "需要相机权限",
            "扫包装上的条码，或直接认包装上印的颜色名。",
            "识别在本机完成，画面不保存、不上传。"
        ),
        (
            "bell.badge.fill",
            "需要通知权限",
            "保湿计时到点时提醒你该给颜料喷水了。",
            "本地通知，不需要联网。"
        )
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $step) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    pageView(page).tag(index)
                }
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            actionBar
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func pageView(_ page: (symbol: String, title: String, body: String, note: String)) -> some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: page.symbol)
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Theme.accent)

            Text(page.title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(page.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 32)

            Text(page.note)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 40)
                .padding(.top, 4)

            Spacer()
        }
        .padding()
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            if step < pages.count - 1 {
                Button {
                    withAnimation { step += 1 }
                } label: {
                    Text("继续").frame(maxWidth: .infinity)
                }
                .artProminentButton()
                .controlSize(.large)

                Button("跳过") { finish() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    Task {
                        await coordinator.requestAll()
                        finish()
                    }
                } label: {
                    Group {
                        if coordinator.isRequesting {
                            HStack(spacing: 8) {
                                ProgressView().tint(.white)
                                Text("正在申请…")
                            }
                        } else {
                            Text("允许并开始使用")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .artProminentButton()
                .controlSize(.large)
                .disabled(coordinator.isRequesting)

                Button("以后再说") { finish() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
        .padding(.top, 8)
    }

    private func finish() {
        coordinator.completeOnboarding()
        onFinish()
    }
}
