//
//  PencilCanvasView.swift
//  ArtAssist — 美术生的工具箱
//
//  Apple Pencil 批注层。用 PencilKit。
//
//  ── 为什么用 PencilKit 而不是自己画线 ────────────────────────
//  自己用 `Canvas` + `DragGesture` 画线，会丢掉笔的全部价值：
//    · 压感与倾斜（美术生圈重点、画结构线时手感差别很大）
//    · 低延迟（PencilKit 走的是系统级的预测与合成，
//      自绘至少差一个数量级，写起来像在拖一条绳子）
//    · 防误触（手掌按在屏幕上不会留痕）
//    · 撤销/重做栈、橡皮、笔宽笔色 —— 全是白送的
//  这三样正是"适配 Apple Pencil"的全部意义，自己实现等于没适配。
//
//  ── 最要紧的一条设计：笔和手指分工 ──────────────────────────
//  `drawingPolicy = .pencilOnly` ——
//      **笔：画。手指：翻页、缩放。**
//  这不是省事，是阅读器唯一说得通的交互：
//  美术生一手拿笔圈画，另一只手（或同一只手的拇指）翻页。
//  如果手指也能画，就没法翻页了；如果笔也能翻页，就没法画了。
//
//  有意思的是这条**故意不跟随系统设置**：
//  系统里有「只使用 Apple Pencil 绘图」的开关，那是给绘画 App 的。
//  阅读器必须一直是 pencilOnly，否则手指一拖就在页面上留一道线。
//  这一点在界面上会跟用户说明。
//
//  ── 批注模式下怎么翻页 ───────────────────────────────────────
//  `PKCanvasView` 是 `UIScrollView` 的子类，它会吞掉手指的拖动。
//  所以批注模式下用两个 `UISwipeGestureRecognizer`（左/右）翻页 ——
//  滑动手势和"用笔画一笔"在触摸类型上就是两回事，不会互相干扰。
//

import PencilKit
import SwiftUI
import UIKit

// MARK: - 批注工具

/// 画笔工具。只留美术生批注真正用得上的三种。
enum AnnotationTool: String, CaseIterable, Identifiable, Sendable {
    /// 细笔：画结构线、圈细节。
    case thin
    /// 粗笔：大面积标记。
    case thick
    /// 荧光笔：半透明，盖住重点但还看得见底下的图。
    case marker
    /// 橡皮。
    case eraser

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .thin: return "细笔"
        case .thick: return "粗笔"
        case .marker: return "荧光笔"
        case .eraser: return "橡皮"
        }
    }

    var symbolName: String {
        switch self {
        case .thin: return "pencil"
        case .thick: return "pencil.tip"
        case .marker: return "highlighter"
        case .eraser: return "eraser"
        }
    }

    /// 转成 PencilKit 的工具。
    func pkTool(color: Color) -> PKTool {
        switch self {
        case .eraser:
            return PKEraserTool(.vector)
        case .marker:
            // 荧光笔：用 marker 笔尖 + 半透明颜色
            return PKInkingTool(.marker, color: UIColor(color.opacity(0.45)), width: 22)
        case .thin:
            return PKInkingTool(.pen, color: UIColor(color), width: 2.6)
        case .thick:
            return PKInkingTool(.pen, color: UIColor(color), width: 7)
        }
    }
}

/// 批注颜色。取的是色卡上那几个明确好认的颜色。
enum AnnotationColor: String, CaseIterable, Identifiable, Sendable {
    case red, orange, green, blue, purple, graphite

    var id: String { rawValue }

    var hex: String {
        switch self {
        case .red: return "#E23B2E"
        case .orange: return "#F5A708"
        case .green: return "#2E9E4F"
        case .blue: return "#1D6FE0"
        case .purple: return "#7B3FD4"
        case .graphite: return "#2B2B30"
        }
    }

    var displayName: String {
        switch self {
        case .red: return "红"
        case .orange: return "橙"
        case .green: return "绿"
        case .blue: return "蓝"
        case .purple: return "紫"
        case .graphite: return "深灰"
        }
    }
}

// MARK: - 画布

/// PencilKit 画布的 SwiftUI 包装。
struct PencilCanvasView: UIViewRepresentable {

    /// 当前页的笔迹。
    @Binding var drawing: PKDrawing
    /// 当前工具。
    var tool: AnnotationTool
    /// 当前颜色。
    var color: Color
    /// 是否接管笔的输入（浏览模式下为 false，笔也能翻页）。
    var isEnabled: Bool
    /// 笔迹变化时回调（用于保存与标记"这一页有批注"）。
    var onChange: (PKDrawing) -> Void
    /// 手指左右滑动 → 翻页。批注模式下画布会吞掉手指，所以用滑动手势兜住。
    var onSwipe: (SwipeDirection) -> Void

    enum SwipeDirection { case previous, next }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        // ★ 关键：只认笔，不认手指。手指留给翻页与缩放。
        canvas.drawingPolicy = .pencilOnly
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // 画布自己不要滚动 —— 页码定位由外层负责，否则两个滚动会打架
        canvas.isScrollEnabled = false
        canvas.delegate = context.coordinator
        canvas.drawing = drawing
        canvas.tool = tool.pkTool(color: color)

        // 手指滑动翻页。滑动手势和笔画是不同触摸类型，不会冲突。
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
            let swipe = UISwipeGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handleSwipe(_:))
            )
            swipe.direction = direction
            swipe.numberOfTouchesRequired = 1
            // 划得快一点才算翻页，避免和"按住不动"混淆
            swipe.cancelsTouchesInView = false
            canvas.addGestureRecognizer(swipe)
        }

        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.parent = self

        // 外部换了页 → 换一张图
        if canvas.drawing.dataRepresentation() != drawing.dataRepresentation() {
            // 正在画的时候不要打断（会丢笔画）
            if !context.coordinator.isDrawing {
                canvas.drawing = drawing
            }
        }

        canvas.tool = tool.pkTool(color: color)
        // 浏览模式下禁掉笔的输入，笔也用来翻页
        canvas.isUserInteractionEnabled = isEnabled
        canvas.alpha = isEnabled ? 1 : 0
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: PencilCanvasView
        /// 正在落笔。用来避免外部刷新打断当前笔画。
        private(set) var isDrawing = false

        init(parent: PencilCanvasView) {
            self.parent = parent
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            isDrawing = true
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            isDrawing = false
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
            parent.onChange(canvasView.drawing)
        }

        @objc func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
            switch gesture.direction {
            case .left: parent.onSwipe(.next)
            case .right: parent.onSwipe(.previous)
            default: break
            }
        }
    }
}

// MARK: - 工具条

/// 批注工具条。自己画而不是用 `PKToolPicker`。
///
/// 为什么不用系统的 `PKToolPicker`：
///   · 它是给绘画 App 的，工具一大堆（钢笔/铅笔/马克笔/尺子/套索…），
///     阅读批注只需要"细笔 / 粗笔 / 荧光笔 / 橡皮"
///   · 它是浮动面板，会盖住教材页面 —— 而看教材时页面本身就是要看的东西
///   · 它需要自己管 first responder 与 window 的绑定，在 SwiftUI 里很别扭
/// 自定义的这排按钮还能跟 App 的玻璃风格统一。
struct AnnotationToolbar: View {

    @Binding var tool: AnnotationTool
    @Binding var color: AnnotationColor
    var canUndo: Bool
    var canRedo: Bool
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onClearPage: () -> Void
    var onDone: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ForEach(AnnotationTool.allCases) { item in
                    Button {
                        tool = item
                        Haptics.selection()
                    } label: {
                        Image(systemName: item.symbolName)
                            .font(.system(size: 17, weight: .medium))
                            .frame(width: 42, height: 42)
                            .background(
                                tool == item ? Theme.accent.opacity(0.22) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                            )
                    }
                    .tint(tool == item ? Theme.accent : .primary)
                    .accessibilityLabel(item.displayName)
                }

                Divider().frame(height: 26)

                // 颜色只在画笔模式下有意义
                if tool != .eraser {
                    ForEach(AnnotationColor.allCases) { item in
                        Button {
                            color = item
                            Haptics.selection()
                        } label: {
                            Circle()
                                .fill(Color(hex: item.hex) ?? .gray)
                                .frame(width: 26, height: 26)
                                .overlay(
                                    Circle().strokeBorder(
                                        color == item ? Color.primary : Color.clear,
                                        lineWidth: 2.5
                                    )
                                )
                        }
                        .accessibilityLabel(item.displayName)
                    }
                }
            }

            HStack(spacing: 18) {
                Button {
                    onUndo()
                } label: {
                    Label("撤销", systemImage: "arrow.uturn.backward")
                        .labelStyle(.iconOnly)
                }
                .disabled(!canUndo)

                Button {
                    onRedo()
                } label: {
                    Label("重做", systemImage: "arrow.uturn.forward")
                        .labelStyle(.iconOnly)
                }
                .disabled(!canRedo)

                Button(role: .destructive) {
                    onClearPage()
                } label: {
                    Label("清除本页", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }

                Spacer()

                Button {
                    onDone()
                } label: {
                    Text("完成批注")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .font(.system(size: 16))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .artGlassSurface(cornerRadius: 20)
    }
}

// MARK: - 系统 Pencil 手势的偏好

/// 双击/捏合该干什么。
///
/// 用户在系统设置里能把这些手势绑到不同动作上（切换橡皮、呼出调色盘、
/// 或者干脆关掉）。**必须尊重**：他明确关掉了，我们装作没看见就是 bug。
enum PencilIntent: Equatable {
    /// 什么都不做（用户设置成了「忽略」，或在无障碍里关了笔交互）。
    case ignore
    /// 进入/退出批注。
    case toggleAnnotation
    /// 切到橡皮。
    case eraser
    /// 切回细笔。
    case pen
}

/// 把系统偏好翻译成我们要做的事。
///
/// 读的是 UIKit 的类属性而不是 SwiftUI 的 `\.preferredPencilDoubleTapAction`：
///   · `UIPencilInteraction.preferredTapAction` 从 iOS 12.1 就有，
///     本工程最低 17.0，不用加版本守卫
///   · SwiftUI 那两个环境值要 17.5，为它单独包一层 `@available` 视图不划算
enum PencilPreference {

    /// 双击笔身的偏好。
    static var doubleTapIntent: PencilIntent {
        switch UIPencilInteraction.preferredTapAction {
        case .ignore:
            return .ignore
        case .switchEraser:
            return .eraser
        case .switchPrevious:
            return .pen
        case .showColorPalette, .showInkAttributes, .showContextualPalette:
            return .toggleAnnotation
        default:
            // 包括 .runSystemShortcut：交给系统，我们不动
            return .ignore
        }
    }

    /// 捏合笔身的偏好（Pencil Pro，iOS 17.5+）。
    static var squeezeIntent: PencilIntent {
        guard #available(iOS 17.5, *) else { return .ignore }
        switch UIPencilInteraction.preferredSqueezeAction {
        case .ignore, .runSystemShortcut:
            return .ignore
        case .switchEraser:
            return .eraser
        case .switchPrevious:
            return .pen
        default:
            // Pencil Pro 捏合默认就是「呼出上下文调色盘」，对阅读器来说
            // 最自然的对应就是进入批注并露出工具条。
            return .toggleAnnotation
        }
    }

    /// 系统是否开着「只使用 Apple Pencil 绘图」。
    ///
    /// 阅读器**故意不跟随**这个设置（见文件头），但界面上要能解释清楚，
    /// 所以把它读出来展示。
    static var prefersPencilOnlyDrawing: Bool {
        UIPencilInteraction.prefersPencilOnlyDrawing
    }
}

// MARK: - SwiftUI 接线

/// Apple Pencil 双击 / 捏合。
///
/// ⚠️ `.onPencilDoubleTap` 与 `.onPencilSqueeze` 都是 **iOS 17.5+**，
///    而本工程最低 17.0 —— 所以必须包在 `#available` 里，
///    而且 `body` 要标 `@ViewBuilder` 才能分支返回不同类型。
struct PencilShortcutModifier: ViewModifier {

    var onDoubleTap: () -> Void
    var onSqueeze: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 17.5, *) {
            content
                .onPencilDoubleTap { _ in onDoubleTap() }
                .onPencilSqueeze { phase in
                    // 只在按下的一瞬间触发，松开不管
                    if case .active = phase { onSqueeze() }
                }
        } else {
            content
        }
    }
}

extension View {
    /// 接上 Apple Pencil 的双击与捏合。17.5 以下什么都不做。
    func pencilShortcuts(
        onDoubleTap: @escaping () -> Void,
        onSqueeze: @escaping () -> Void
    ) -> some View {
        modifier(PencilShortcutModifier(onDoubleTap: onDoubleTap, onSqueeze: onSqueeze))
    }
}
