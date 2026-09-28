//
//  LiquidGlass.swift
//  ArtAssist — 美术生的工具箱
//
//  iOS 26 Liquid Glass 适配层。
//
//  ── 签名核实记录 ──────────────────────────────────────────────
//  本文件用到的 iOS 26 API 均已逐条比对 Apple 官方文档：
//    · glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape())
//    · Glass.regular / Glass.clear
//    · Glass.interactive(_ isEnabled: Bool = true) -> Glass
//    · Glass.tint(_:) -> Glass
//    · GlassEffectContainer.init(spacing: CGFloat? = nil, @ContentBuilder content: () -> Content)
//    · PrimitiveButtonStyle.glass / .glassProminent
//    · scrollEdgeEffectStyle(_ style: ScrollEdgeEffectStyle?, for edges: Edge.Set)，.soft / .hard
//    · backgroundExtensionEffect()
//
//  刻意不使用 `Shape.rect(cornerRadius:)` 简写：官方文档页没有暴露 `style`
//  参数是否带默认值，因此改用 `RoundedRectangle(cornerRadius:style:)` 与
//  `Circle()` —— 这两个从 iOS 13 起签名就稳定且无歧义。
//
//  ── 风险隔离 ──────────────────────────────────────────────────
//  全工程只有本文件直接调用上述符号。双重门控：
//    1. `#if compiler(>=6.2)` —— 工具链过旧时整块退化为材质版本
//    2. `if #available(iOS 26.0, *)` —— 运行时按系统版本分流
//  万一某个签名仍有出入，编译错误只会落在这里，删掉对应一行即可，
//  App 其余部分与"第 1 层自动适配"完全不受影响。
//
//  ── 最重要的一条 ──────────────────────────────────────────────
//  最大的一层液态玻璃适配**不需要任何代码**：只要用 iOS 26 SDK 构建、
//  且 Info.plist 不设 UIDesignRequiresCompatibility，导航栏、工具栏、
//  侧边栏、表单、菜单、搜索框、Sheet 会自动采用新外观。
//  本文件只负责系统没覆盖到的自定义表面。
//

import SwiftUI

// MARK: - 玻璃表面

extension View {

    /// 玻璃表面。用于浮在内容之上的自定义控件（扫码取景框上的按钮组、浮动操作条）。
    ///
    /// 对应 `glassEffect(_:in:)`，`Glass.regular` 是官方默认变体。
    /// - Parameters:
    ///   - cornerRadius: 圆角半径。
    ///   - interactive: 是否启用 `Glass.interactive()`，让玻璃随触摸产生形变反馈。
    @ViewBuilder
    func artGlassSurface(cornerRadius: CGFloat = 16, interactive: Bool = false) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(
                interactive ? Glass.regular.interactive() : Glass.regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self.artMaterialFallback(cornerRadius: cornerRadius)
        }
        #else
        self.artMaterialFallback(cornerRadius: cornerRadius)
        #endif
    }

    /// 圆形玻璃表面，用于图标按钮。
    @ViewBuilder
    func artGlassCircle(interactive: Bool = true) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(
                interactive ? Glass.regular.interactive() : Glass.regular,
                in: Circle()
            )
        } else {
            self.artMaterialFallback(cornerRadius: 999)
        }
        #else
        self.artMaterialFallback(cornerRadius: 999)
        #endif
    }

    /// 带色彩倾向的玻璃。用于"连续扫描已开启"这类需要一眼看出状态的按钮。
    @ViewBuilder
    func artTintedGlassSurface(tint: Color, cornerRadius: CGFloat = 16) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.glassEffect(
                Glass.regular.tint(tint).interactive(),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self.artTintedFallback(tint: tint, cornerRadius: cornerRadius)
        }
        #else
        self.artTintedFallback(tint: tint, cornerRadius: cornerRadius)
        #endif
    }

    /// 低版本降级外观（中性）。刻意做得和玻璃接近，避免两套视觉差异过大。
    private func artMaterialFallback(cornerRadius: CGFloat) -> some View {
        self
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// 低版本降级外观（着色）。
    private func artTintedFallback(tint: Color, cornerRadius: CGFloat) -> some View {
        self
            .background(.ultraThinMaterial,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint.opacity(0.22))
                    .allowsHitTesting(false)
            }
    }

    // MARK: - 滚动边缘

    /// 滚动内容进入导航栏 / 工具栏时出现柔和渐隐，而不是生硬的裁切线。
    ///
    /// 对应 `scrollEdgeEffectStyle(_:for:)`，固定使用 `.soft`（柔和模糊过渡；
    /// `.hard` 是清晰线性边界，本 App 的列表更适合柔和版）。
    ///
    /// ⚠️ 这里**刻意不接受 `ScrollEdgeEffectStyle` 参数**——这一点很反直觉，但是实测踩过的坑：
    /// `ScrollEdgeEffectStyle` 类型本身是 iOS 26.0+ 才引入的。只要它出现在函数签名里，
    /// 即使函数体被 `if #available(iOS 26.0, *)` 完整门控，部署目标为 iOS 17 时依然报
    ///   error: 'ScrollEdgeEffectStyle' is only available in iOS 26.0 or newer
    /// （可用性检查保护函数体，但保护不了签名里的类型。）
    ///
    /// 将来若真需要按场景切换样式，正确做法是声明一个自定义枚举，
    /// 在 `#available` 分支内部再映射成 `ScrollEdgeEffectStyle`。
    @ViewBuilder
    func artScrollEdgeEffect() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// 让头图延伸到侧边栏下方，形成沉浸式背景。
    ///
    /// 官方明确建议：整个界面只对**一处**背景内容使用，并考虑性能开销。
    @ViewBuilder
    func artBackgroundExtension() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.backgroundExtensionEffect()
        } else {
            self
        }
        #else
        self
        #endif
    }
}

// MARK: - 按钮样式

extension View {

    /// 主要操作按钮。对应 `PrimitiveButtonStyle.glassProminent`。
    @ViewBuilder
    func artProminentButton() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
        #else
        self.buttonStyle(.borderedProminent)
        #endif
    }

    /// 次要操作按钮。对应 `PrimitiveButtonStyle.glass`。
    @ViewBuilder
    func artGlassButton() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
        #else
        self.buttonStyle(.bordered)
        #endif
    }
}

// MARK: - 玻璃容器

/// 把相邻的多个玻璃元素放进同一个容器，让它们的折射与形变互相融合。
///
/// 对应 `GlassEffectContainer(spacing:content:)`：容器内各形状靠近时会互相融合，
/// spacing 越大越早开始融合；nil 表示使用系统默认间距。
/// iOS 26 以下为纯透传，不影响布局。
struct ArtGlassContainer<Content: View>: View {

    /// 融合间距。nil 时使用系统默认值。
    var spacing: CGFloat?

    let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - 能力探测

enum LiquidGlassSupport {

    /// 当前运行环境是否真的支持自定义玻璃效果。
    /// 界面可据此决定要不要额外补一层描边（玻璃本身已有边界，不需要）。
    static var isAvailable: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    /// 供「关于」页面展示的一行说明。
    static var description: String {
        isAvailable
            ? "已启用 iOS 26 液态玻璃外观"
            : "当前系统低于 iOS 26，使用材质降级外观"
    }
}
