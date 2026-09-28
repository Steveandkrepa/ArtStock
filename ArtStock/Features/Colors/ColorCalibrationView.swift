//
//  ColorCalibrationView.swift
//  ArtAssist — 美术生的工具箱
//
//  取色校准：把打开的颜料盒对着相机，屏幕上实时显示**即将写进每一格的颜色**，
//  确认了再保存。
//
//  ── 为什么必须让用户自己采 ───────────────────────────────────
//  真实反馈两条，都指向同一件事：
//    · 「像马尔代夫就根本不像啊颜色，是个绿色的，显示个蓝色的」
//    · 「颜色到底啥样直接采用标准的国际数据」
//
//  第二条做不到 —— 颜料没有 RGB 的国际标准（Colour Index 只规定化学成分），
//  而「马尔代夫」「起司」「浅蟹灰」是**品牌自创色名**，马利、米娅、温莎
//  各家调出来都不一样，没有任何公开色值可查。我当初照 W3C 的 turquoise
//  硬套，套出来当然是蓝的。
//
//  所以正解不是"找个更权威的表"，而是**从你的实物上采**。
//
//  ── 为什么是"实时马赛克"而不是"拍一张照" ──────────────────
//  拍照方案要处理透视、角度、镜头畸变，任何一处算错都会采偏半格，
//  而用户**看不出来** —— 他会以为"这 App 采色不准"。
//
//  实时马赛克把这个风险消掉了：屏幕上那 42 个小色块就是即将保存的值，
//  用户拿它跟实物一比就知道准不准，不准就拖一下框、再比一次。
//  所见即所得，不需要相信我的几何。
//

import CoreVideo
import SwiftData
import SwiftUI

struct ColorCalibrationView: View {

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \PaletteBox.createdAt) private var boxes: [PaletteBox]

    @State private var proxy = ColorSamplerProxy()

    /// 采样框（归一化坐标）。用户拖动/缩放它去对齐实物颜料盒。
    @State private var grid = CGRect(x: 0.07, y: 0.13, width: 0.86, height: 0.74)
    /// 每格往里收多少 —— 避开格子之间的塑料隔断。
    @State private var inset: Double = 0.22

    /// 实时采到的颜色（行优先，长度 = rows × columns）。
    @State private var sampled: [RGBColor?] = []
    /// 缓冲像素尺寸 —— 算格子线位置要用。
    @State private var bufferSize: CGSize = .zero
    /// 拖动开始时的采样框，避免边拖边累加导致漂移。
    @State private var dragOrigin: CGRect?
    @State private var pinchOrigin: CGRect?

    @State private var isShowingFineTune = false
    @State private var outcome: String?

    private var box: PaletteBox? { boxes.first }
    private var rows: Int { max(1, box?.rows ?? 7) }
    private var columns: Int { max(1, box?.columns ?? 6) }
    private var cellCount: Int { rows * columns }

    /// 已经采到值的格子数。
    private var filledCount: Int {
        sampled.prefix(cellCount).compactMap { $0 }.count
    }

    /// 有颜色、而且采样值跟当前色值不一样的格子数 —— 也就是"这次会改掉几格"。
    private var changedCount: Int {
        guard let box else { return 0 }
        let wells = box.orderedWells
        var count = 0
        for (index, well) in wells.enumerated() {
            guard index < sampled.count, let color = well.color, let rgb = sampled[index] else { continue }
            if color.hex.uppercased() != rgb.hex { count += 1 }
        }
        return count
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ColorSamplerView(
                onFrame: handleFrame,
                onStateChange: {},
                controllerProxy: proxy
            )
            .ignoresSafeArea()

            gridOverlay

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if let outcome {
                    Text(outcome)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .artGlassSurface(cornerRadius: 999)
                        .padding(.bottom, 12)
                }
                bottomPanel
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .persistentSystemOverlays(.hidden)
        .onAppear { resetSamples() }
        .onChange(of: cellCount) { _, _ in resetSamples() }
    }

    // MARK: - 格子线

    /// 把采样框画在画面上。
    ///
    /// 位置用 `ColorGridSampler.displayRect` 算 —— 跟采样的坐标来源完全一致，
    /// 所以**线框里的东西就是被采样的东西**。
    private var gridOverlay: some View {
        GeometryReader { geometry in
            let display = ColorGridSampler.displayRect(
                bufferSize: bufferSize, in: geometry.size, fill: true
            )

            ZStack {
                if bufferSize != .zero {
                    Canvas { canvasContext, _ in
                        let rects = ColorGridSampler.cellRects(
                            grid: grid, rows: rows, columns: columns, inset: 0
                        )
                        // 逐格描线：让用户看清"每格对应哪个颜色"，
                        // 而不是只有一个大框（大框对不齐时看不出来偏在哪一格）。
                        for rect in rects {
                            let path = Path { path in
                                let points = [
                                    CGPoint(x: rect.minX, y: rect.minY),
                                    CGPoint(x: rect.maxX, y: rect.minY),
                                    CGPoint(x: rect.maxX, y: rect.maxY),
                                    CGPoint(x: rect.minX, y: rect.maxY)
                                ].map { ColorGridSampler.viewPoint($0, displayRect: display) }
                                path.addLines(points)
                                path.closeSubpath()
                            }
                            canvasContext.stroke(
                                path,
                                with: .color(.white.opacity(0.55)),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                            )
                        }

                        // 外框画粗一点
                        let outline = Path { path in
                            let points = [
                                CGPoint(x: grid.minX, y: grid.minY),
                                CGPoint(x: grid.maxX, y: grid.minY),
                                CGPoint(x: grid.maxX, y: grid.maxY),
                                CGPoint(x: grid.minX, y: grid.maxY)
                            ].map { ColorGridSampler.viewPoint($0, displayRect: display) }
                            path.addLines(points)
                            path.closeSubpath()
                        }
                        canvasContext.stroke(
                            outline, with: .color(.white.opacity(0.95)), lineWidth: 2
                        )
                    }
                    .allowsHitTesting(false)

                    // 拖动 / 缩放采样框
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(dragGesture(display: display))
                        .simultaneousGesture(magnifyGesture(display: display))
                }
            }
        }
    }

    private func dragGesture(display: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard display.width > 1, display.height > 1 else { return }
                let origin = dragOrigin ?? grid
                if dragOrigin == nil { dragOrigin = origin }
                // 屏幕位移 → 归一化位移。除以 display 尺寸而不是视图尺寸，
                // 因为画面是 aspectFill 铺满的，可能比视图还大。
                let dx = value.translation.width / display.width
                let dy = value.translation.height / display.height
                grid = clamp(
                    CGRect(x: origin.minX + dx, y: origin.minY + dy,
                           width: origin.width, height: origin.height)
                )
            }
            .onEnded { _ in dragOrigin = nil }
    }

    private func magnifyGesture(display: CGRect) -> some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                guard display.width > 1, display.height > 1 else { return }
                let origin = pinchOrigin ?? grid
                if pinchOrigin == nil { pinchOrigin = origin }
                let newWidth = origin.width * scale
                let newHeight = origin.height * scale
                // 以中心为锚点缩放
                grid = clamp(CGRect(
                    x: origin.midX - newWidth / 2,
                    y: origin.midY - newHeight / 2,
                    width: newWidth,
                    height: newHeight
                ))
            }
            .onEnded { _ in pinchOrigin = nil }
    }

    /// 采样框不许跑出画面，也不许小到没法用。
    private func clamp(_ rect: CGRect) -> CGRect {
        let minSide = 0.15
        var width = min(max(rect.width, minSide), 1.0)
        var height = min(max(rect.height, minSide), 1.0)
        var x = min(max(rect.minX, 0), 1 - width)
        var y = min(max(rect.minY, 0), 1 - height)
        // 先夹位置再校正宽高，避免"夹完又跑出去"
        width = min(width, 1 - x)
        height = min(height, 1 - y)
        x = max(0, x)
        y = max(0, y)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .frame(width: 44, height: 44)
                    .artGlassCircle()
            }
            .tint(.white)
            .accessibilityLabel("关闭")

            VStack(alignment: .leading, spacing: 2) {
                Text("取色校准")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("把打开的颜料盒对进虚线框，拖动移动、双指缩放")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(2)
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if proxy.isTorchAvailable {
                Button {
                    proxy.toggleTorch()
                    Haptics.selection()
                } label: {
                    Image(systemName: proxy.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.headline)
                        .frame(width: 44, height: 44)
                        .artGlassCircle()
                }
                .tint(proxy.isTorchOn ? Theme.accent : .white)
                .accessibilityLabel("手电筒")
            }
        }
    }

    // MARK: - 底部面板

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = proxy.captureError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .center, spacing: 14) {
                    mosaic

                    VStack(alignment: .leading, spacing: 4) {
                        Text("即将保存的颜色")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("跟实物比一下")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.65))
                        Text("采到 \(filledCount) / \(cellCount) 格")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.65))
                        if changedCount > 0 {
                            Text("会改掉 \(changedCount) 格")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.green)
                        } else if filledCount > 0 {
                            Text("跟当前色值一致")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    Button {
                        isShowingFineTune = true
                    } label: {
                        Label("微调", systemImage: "slider.horizontal.3")
                    }
                    .artGlassButton()
                    .controlSize(.large)
                    .tint(.white)

                    Button {
                        save()
                    } label: {
                        Label("就按这一组", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .artProminentButton()
                    .controlSize(.large)
                    .disabled(filledCount == 0 || changedCount == 0)
                }

                Text("保存后这些颜色会标为「已校准」，不会被「刷成标准值」覆盖。")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .artGlassSurface(cornerRadius: 22)
        .sheet(isPresented: $isShowingFineTune) {
            fineTuneSheet
        }
        .alert("取色完成", isPresented: .presentWhen($outcome)) {
            Button("好") { outcome = nil; dismiss() }
            Button("继续校准") { outcome = nil }
        } message: {
            Text(outcome ?? "")
        }
    }

    /// 实时马赛克：按盒子的排布显示采到的颜色。
    private var mosaic: some View {
        let wells = box?.orderedWells ?? []
        return VStack(spacing: 2) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 2) {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        let color = index < sampled.count ? sampled[index] : nil
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color.map { Color(red: $0.r, green: $0.g, blue: $0.b) }
                                  ?? Color(white: 0.25))
                            .frame(width: 13, height: 13)
                            .overlay {
                                // 空格子（没装颜色）不打点，让用户知道这一格采了也不会保存
                                if index < wells.count, wells[index].color == nil {
                                    Circle()
                                        .fill(.white.opacity(0.7))
                                        .frame(width: 3, height: 3)
                                }
                            }
                    }
                }
            }
        }
        .padding(6)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - 微调

    private var fineTuneSheet: some View {
        NavigationStack {
            Form {
                Section {
                    slider("宽度", value: $grid.size.width, range: 0.15...1.0)
                    slider("高度", value: $grid.size.height, range: 0.15...1.0)
                    slider("横向位置", value: $grid.origin.x, range: 0...1)
                    slider("纵向位置", value: $grid.origin.y, range: 0...1)
                } header: {
                    Text("采样框")
                } footer: {
                    Text("拖动和双指缩放不够精细时用这里。框要对准**盒子外框**，"
                         + "不是对准颜料格 —— 内部会按 \(rows)×\(columns) 自动均分。")
                }

                Section {
                    slider("取样范围", value: $inset, range: 0.0...0.45)
                } header: {
                    Text("每格取多少")
                } footer: {
                    Text("格子之间通常有塑料隔断。数值越大越往中间收，"
                         + "采到的越接近纯颜料；采出来偏灰就调大它。")
                }

                Section {
                    Button {
                        grid = CGRect(x: 0.07, y: 0.13, width: 0.86, height: 0.74)
                        inset = 0.22
                        Haptics.selection()
                    } label: {
                        Label("恢复默认框", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("微调采样框")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("好") { isShowingFineTune = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// 采样框的分量是 `CGFloat`（CGRect 的定义），而 `Slider` 要 `Double`，
    /// 所以两个重载各管一路，内部都收敛到同一个画法。
    private func slider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<Double>) -> some View {
        sliderBody(title: title, value: Binding<Double>(
            get: { Double(value.wrappedValue) },
            set: { value.wrappedValue = CGFloat($0) }
        ), range: range)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        sliderBody(title: title, value: value, range: range)
    }

    private func sliderBody(title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    // MARK: - 采样

    private func resetSamples() {
        sampled = Array(repeating: nil, count: cellCount)
    }

    private func handleFrame(_ buffer: CVPixelBuffer, size: CGSize) {
        bufferSize = size

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        let fresh = ColorGridSampler.sampleGridColors(
            bgra: base.assumingMemoryBound(to: UInt8.self),
            bytesPerRow: bytesPerRow,
            width: width,
            height: height,
            grid: grid,
            rows: rows,
            columns: columns,
            inset: inset
        )

        // 时域平滑：否则每秒 4 次的马赛克会一直在抖，用户根本按不下按钮。
        var blended: [RGBColor?] = []
        blended.reserveCapacity(fresh.count)
        for index in 0..<fresh.count {
            let previous = index < sampled.count ? sampled[index] : nil
            blended.append(ColorGridSampler.blend(previous: previous, next: fresh[index], factor: 0.45))
        }
        sampled = blended
    }

    // MARK: - 保存

    private func save() {
        guard let box else { return }
        let wells = box.orderedWells
        let now = Date.now
        var changed = 0
        var stamped = 0

        for (index, well) in wells.enumerated() {
            guard let color = well.color else { continue }
            guard index < sampled.count, let rgb = sampled[index] else { continue }
            let hex = rgb.hex
            if color.hex.uppercased() != hex {
                color.hex = hex
                changed += 1
            }
            color.calibratedAt = now
            color.updatedAt = now
            stamped += 1
        }

        try? context.save()
        Haptics.saved()

        var message = "从实物上采了 \(stamped) 格的颜色，其中 \(changed) 格有变化。"
        let emptyOrMissing = wells.count - stamped
        if emptyOrMissing > 0 {
            // 空格子或没采到值的格子要说清楚，不然用户会以为漏了
            message += "\n还有 \(emptyOrMissing) 格没保存：要么那一格没装颜色，要么没采到值。"
        }
        message += "\n这些颜色已标记为「已校准」，「刷成标准值」不会再覆盖它们。"
        outcome = message
    }
}
