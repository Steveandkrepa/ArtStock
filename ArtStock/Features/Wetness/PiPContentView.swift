//
//  PiPContentView.swift
//  ArtAssist — 美术生的工具箱
//
//  画中画窗口里显示的内容。
//
//  设计约束：PiP 窗口可能只有指甲盖那么大，而且是在你画画时用眼角余光看的。
//  所以这里只有三个信息层级：
//      1. 还剩多久（最大、最粗）
//      2. 喷几下（第二重要）
//      3. 是哪盘颜料（小字，确认用）
//  颜色随紧急程度变化 —— 不用读数字，扫一眼颜色就知道该不该动手。
//

import SwiftUI

struct PiPContentView: View {

    let content: PiPContent

    /// 按紧急程度取背景色。越接近补水时刻越暖、越扎眼。
    private var backgroundColors: [Color] {
        if content.isOverdue {
            return [Color(red: 0.55, green: 0.06, blue: 0.10),
                    Color(red: 0.32, green: 0.03, blue: 0.07)]
        }
        switch content.urgency {
        case ..<0.4:
            return [Color(red: 0.08, green: 0.30, blue: 0.36),
                    Color(red: 0.04, green: 0.16, blue: 0.22)]
        case ..<0.75:
            return [Color(red: 0.42, green: 0.28, blue: 0.04),
                    Color(red: 0.22, green: 0.13, blue: 0.02)]
        default:
            return [Color(red: 0.48, green: 0.14, blue: 0.04),
                    Color(red: 0.26, green: 0.06, blue: 0.02)]
        }
    }

    private var accentColor: Color {
        if content.isOverdue { return Color(red: 1.0, green: 0.42, blue: 0.42) }
        switch content.urgency {
        case ..<0.4: return Color(red: 0.45, green: 0.92, blue: 0.85)
        case ..<0.75: return Color(red: 1.0, green: 0.80, blue: 0.35)
        default: return Color(red: 1.0, green: 0.58, blue: 0.30)
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: backgroundColors,
                           startPoint: .topLeading, endPoint: .bottomTrailing)

            VStack(spacing: 0) {
                // 顶部：哪盘颜料 + 状态
                HStack(spacing: 6) {
                    Text(content.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if content.isOverdue {
                        Text("该喷了")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.22), in: Capsule())
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)

                Spacer(minLength: 0)

                // 中间：倒计时 —— 这一屏唯一的主角
                Text(content.timeText)
                    .font(.system(size: 68, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.28), radius: 2, y: 1)

                Spacer(minLength: 0)

                // 底部：喷几下
                HStack(spacing: 8) {
                    Image(systemName: "spraybottle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accentColor)

                    if content.sprays > 0 {
                        Text("喷 \(content.sprays) 下")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    } else {
                        Text("未标定喷雾")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
            }
        }
        // 固定尺寸：这个视图是给 ImageRenderer 用的，不受父视图约束。
        .frame(width: 480, height: 270)
    }
}
