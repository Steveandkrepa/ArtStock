//
//  PaintScanView.swift
//  ArtAssist — 美术生的工具箱
//
//  扫颜料包装 → 入库到颜色库。
//
//  ── 两种模式，默认「认字」──────────────────────────────────
//  真实反馈：「颜料本身不同颜色的条形码都是一样的，不是每个颜色一个条形码」。
//
//  这句话把整件事说清楚了 —— 条码里**根本没有颜色信息**。
//  管子上真正每支都不一样的，是印上去的字：群青、钛白、深红。
//  所以默认走「认字」（Vision OCR 读中文颜色名），条码只当批次线索。
//
//  「扫码」模式仍然保留：万一你手上那盒是每个颜色一个码，它更方便。
//  但界面上会明说条码可能共用，不让人白折腾。
//
//  ── 关于 OCR ────────────────────────────────────────────────
//  识别完全在本机完成（Vision），不联网、不上传、不需要额外权限。
//  一帧几百毫秒，所以限流到约每秒一帧，再要求**连续两次读到同一个名字**
//  才显示结果 —— 否则屏幕上的字会一直跳。
//

import AVFoundation
import CoreVideo
import SwiftData
import SwiftUI

struct PaintScanView: View {

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var controller = ScannerController()
    @State private var ocr = LabelOCRService()

    @State private var mode: ScanMode = .text
    @State private var reviewDraft: PaintColorDraft?
    @State private var isShowingManualEntry = false
    @State private var sharedCodeDraft: PaintColorDraft?
    @State private var feedback: String?
    @State private var acceptedCount = 0
    @State private var editingWell: PaletteWell?
    @State private var isShowingRawText = false

    /// 当前稳定下来的认字结果。
    @State private var labelDraft: PaintLabelDraft?
    /// 连续读到同一个名字的计数 —— 用来防抖。
    @State private var pendingName: String?
    @State private var pendingHits = 0
    /// 数码变焦倍数。喷码字小，放大往往比换模型管用。
    @State private var zoom = 1
    /// 图像预处理档位。
    @State private var profile: TextImagePreprocessor.Profile = .none
    /// 用户是否手动切过档位。手动切过就不再自动判断 ——
    /// 否则他刚点开「喷码」，下一帧又被自动切回去，看起来像按钮失灵。
    @State private var profileIsManual = false
    /// 自动判断跑过没有。只在本次扫码里跑一次，不然档位会来回跳。
    @State private var didAutoDetectProfile = false
    /// 用来等画面稳定几帧再判断，第一帧往往还没对上焦。
    @State private var framesSeen = 0
    /// 用户点选的目标中心（归一化的**缓冲**坐标）。nil = 识别整个画面。
    ///
    /// 真照片上验证过：喷码通常不在画面正中 —— 人本能地把整包对进取景框，
    /// 而那行字偏在一侧。原来"放大"是裁中央，正好会把要认的那行裁掉。
    /// 让用户点一下就解决了，比裁中央可靠得多。
    @State private var aimPoint: CGPoint?
    /// 额外旋转 0 / 90 / 270。喷码常常是竖排的（批号沿袋子纵向印）。
    @State private var rotationDegrees = 0
    /// 相机缓冲的像素尺寸。把点击位置换算成缓冲坐标要用它。
    @State private var bufferSize: CGSize = .zero

    /// 去重窗口：相机每帧都会回调，不去重会疯狂触发。
    @State private var recentPayloads: [String: Date] = [:]

    enum ScanMode: String, CaseIterable, Identifiable {
        case text
        case code

        var id: String { rawValue }
        var title: String {
            switch self {
            case .text: return "认字"
            case .code: return "扫码"
            }
        }
        var symbolName: String {
            switch self {
            case .text: return "text.viewfinder"
            case .code: return "barcode.viewfinder"
            }
        }
    }

    /// 有面板弹出来的时候暂停 OCR —— 否则后台还在认，白白烧电。
    private var isPaused: Bool {
        reviewDraft != nil || sharedCodeDraft != nil || isShowingManualEntry
            || editingWell != nil || isShowingRawText
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // ⚠️ 相机视图必须**始终挂载**，不能用 `if 已授权` 包起来。
            //
            // 原因：申请权限的代码写在 QRScannerViewController.viewWillAppear 里，
            // 而那个控制器正是由 QRScannerView 创建的。如果用条件包住，就形成死循环：
            //     未授权 → 不创建控制器 → 不申请 → 永远未授权
            // 实测后果是相机在任何环境下都彻底用不了（不只是 LiveContainer）。
            // 这是本工程踩过的一个真实 bug，别再改回条件挂载。
            QRScannerView(
                controller: controller,
                wantsFrames: mode == .text && !isPaused,
                onCode: { payload, symbology in
                    handle(payload: payload, symbologyRaw: symbology, isManual: false)
                },
                onFrame: { buffer, orientation in
                    handleFrame(buffer, orientation: orientation)
                }
            )
            .ignoresSafeArea()

            // 未授权时把降级界面**盖在上面**，而不是替换掉相机视图。
            if controller.authorization != .authorized {
                cameraFallback.ignoresSafeArea()
            }

            // 点选识别区域的触摸层。
            // 放在相机之上、控件之下 —— 这样点画面能选位置，点按钮还是按钮。
            if mode == .text, controller.authorization == .authorized {
                aimLayer
            }

            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if let feedback {
                    Text(feedback)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .artGlassSurface(cornerRadius: 999)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 14)
                }
                if mode == .text, controller.authorization == .authorized {
                    labelCard
                }
                bottomBar
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .persistentSystemOverlays(.hidden)
        .onAppear {
            recentPayloads.removeAll()
            resetReading()
        }
        .onChange(of: mode) { _, _ in
            resetReading()
            Haptics.selection()
        }
        .sheet(item: $reviewDraft) { draft in
            ScanResultSheet(draft: draft) { addedToWell in
                acceptedCount += 1
                showFeedback(addedToWell ? "已入库并装进格子" : "已存入颜色库")
            }
        }
        .sheet(item: $sharedCodeDraft) { draft in
            SharedBarcodeSheet(draft: draft) { action in
                switch action {
                case .useText:
                    mode = .text
                    showFeedback("已切到认字 —— 对准管子上的颜色名")
                case .nameIt:
                    reviewDraft = draft
                }
            }
        }
        .sheet(isPresented: $isShowingManualEntry) {
            ManualCodeEntryView { payload in
                handle(payload: payload, symbologyRaw: "", isManual: true)
            }
        }
        .sheet(item: $editingWell) { well in
            WellEditorSheet(well: well)
        }
        .sheet(isPresented: $isShowingRawText) {
            RawTextSheet(draft: labelDraft, service: ocr)
        }
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
                Text(mode == .text ? "认包装上的颜色名" : "扫包装上的条码")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(mode == .text
                     ? (controller.authorization == .authorized
                        ? textModeHint
                        : "相机不可用，可用右下角手输")
                     : "同一个品牌的条码常常是共用的")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            if acceptedCount > 0 {
                Text("已入库 \(acceptedCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentTransition(.numericText())
                    .artGlassSurface(cornerRadius: 999)
            }
        }
        .overlay(alignment: .bottom) { modePicker }
        .padding(.bottom, 40)
    }

    private var modePicker: some View {
        Picker("模式", selection: $mode) {
            ForEach(ScanMode.allCases) { item in
                Label(item.title, systemImage: item.symbolName).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 240)
        .offset(y: 12)
    }

    // MARK: - 认字结果卡片

    @ViewBuilder
    private var labelCard: some View {
        if let draft = labelDraft {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(hex: draft.suggestedHex ?? "") ?? Color(white: 0.35))
                        .frame(width: 56, height: 56)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(draft.suggestedName.isEmpty ? "？" : draft.suggestedName)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                            if let ci = draft.ciCode {
                                Text(ci)
                                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.white.opacity(0.18), in: Capsule())
                                    .foregroundStyle(.white)
                            }
                        }

                        Text(detailLine(for: draft))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 6) {
                            Image(systemName: draft.isConfident ? "checkmark.seal.fill" : "questionmark.circle")
                                .font(.caption2)
                            Text(draft.isConfident ? "可以直接入库" : "读到的东西不太确定，确认一下")
                                .font(.caption2)
                            Spacer(minLength: 6)
                            Text("\(Int(draft.confidence * 100))%")
                                .font(.caption2.monospacedDigit())
                        }
                        .foregroundStyle(draft.isConfident ? .green : .orange)
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 10) {
                    Button {
                        acceptLabel(draft)
                    } label: {
                        Label("就是它", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .artProminentButton()
                    .controlSize(.large)

                    Button {
                        resetReading()
                        showFeedback("好，重新读")
                    } label: {
                        Label("重读", systemImage: "arrow.clockwise")
                    }
                    .artGlassButton()
                    .controlSize(.large)
                    .tint(.white)
                }

                Button {
                    isShowingRawText = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.magnifyingglass")
                        Text("看它到底读到了什么")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .artGlassSurface(cornerRadius: 22)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            searchingHint
        }
    }

    private var searchingHint: some View {
        HStack(spacing: 12) {
            if ocr.isBusy {
                ProgressView().tint(.white)
            } else {
                Image(systemName: "text.viewfinder")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(ocr.recognitionCount == 0 ? "正在准备识别…" : "没读到颜色名")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Text("让「群青」「钛白」这样的字占满取景框中间，光线足一点")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .artGlassSurface(cornerRadius: 20)
    }

    /// 用户点选的目标区域（归一化）。
    ///
    /// 取一个**方形**窗口：竖排与横排的字都在里面，不用让用户区分方向。
    /// 边长 0.5 —— 约占画面 1/4 面积，是喷码那行字的两三倍，
    /// 留出余量，用户点得偏一点也还在框里。
    private var aimRect: CGRect? {
        guard let aimPoint else { return nil }
        let side: CGFloat = 0.5
        let x = min(max(0, aimPoint.x - side / 2), 1 - side)
        let y = min(max(0, aimPoint.y - side / 2), 1 - side)
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// 认字模式下的提示。要点明当前开着的辅助开关，
    /// 否则用户会忘了自己两天前点过「喷码」，然后奇怪为什么认不准。
    private var textModeHint: String {
        var parts: [String] = []
        if aimPoint != nil { parts.append("只认点选那块") }
        if rotationDegrees != 0 { parts.append("已转 \(rotationDegrees)°") }
        if zoom > 1 { parts.append("放大 \(zoom)×") }
        if profile == .dotMatrix { parts.append("喷码模式") }
        if parts.isEmpty { return "对准颜色名；字偏在一侧就点一下它" }
        return parts.joined(separator: " · ")
    }

    /// 卡片上的第二行：说清"这个颜色现在是什么状态"。
    private func detailLine(for draft: PaintLabelDraft) -> String {
        if let well = wellHolding(draft) {
            return "颜色库里就有，装在 \(well.positionLabel) 格 · \(draft.matchKind.displayName)"
        }
        if draft.matchedCode != nil {
            return "颜色库里就有 · \(draft.matchKind.displayName)"
        }
        if draft.suggestedName.isEmpty {
            return draft.summary
        }
        return "颜色库里还没有，入库会新建一条"
    }

    /// 这个颜色现在装在哪个格子里。
    private func wellHolding(_ draft: PaintLabelDraft) -> PaletteWell? {
        guard let code = draft.matchedCode else { return nil }
        let boxes = (try? context.fetch(FetchDescriptor<PaletteBox>())) ?? []
        return boxes.first?.orderedWells.first { $0.color?.code == code }
    }

    // MARK: - 点选识别区域

    /// 在画面上点一下，只识别那一块。
    ///
    /// 为什么需要：真照片上那行喷码**不在画面正中** —— 人本能地把整包对进
    /// 取景框，而批号偏在一侧。原来「放大」是裁中央，正好把要认的那行裁掉。
    /// 让用户指一下最省事，也比任何自动检测都准。
    private var aimLayer: some View {
        GeometryReader { geometry in
            let display = ColorGridSampler.displayRect(
                bufferSize: bufferSize, in: geometry.size, fill: true
            )

            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture(count: 1)
                            .onEnded { value in handleAimTap(value.location, display: display) }
                    )

                if let aimRect, display.width > 1 {
                    let topLeft = ColorGridSampler.viewPoint(
                        CGPoint(x: aimRect.minX, y: aimRect.minY), displayRect: display)
                    let size = CGSize(
                        width: aimRect.width * display.width,
                        height: aimRect.height * display.height
                    )
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                        Text("再点框内取消")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.35), in: Capsule())
                            .offset(y: size.height / 2 + 16)
                    }
                    .frame(width: size.width, height: size.height)
                    .position(x: topLeft.x + size.width / 2, y: topLeft.y + size.height / 2)
                    .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func handleAimTap(_ location: CGPoint, display: CGRect) {
        guard display.width > 1, display.height > 1 else { return }

        // 点框内 → 取消
        if let aimRect {
            let topLeft = ColorGridSampler.viewPoint(
                CGPoint(x: aimRect.minX, y: aimRect.minY), displayRect: display)
            let rect = CGRect(
                x: topLeft.x, y: topLeft.y,
                width: aimRect.width * display.width,
                height: aimRect.height * display.height
            )
            if rect.contains(location) {
                aimPoint = nil
                Haptics.selection()
                showFeedback("已取消点选，恢复识别整个画面")
                return
            }
        }

        // 视图坐标 → 缓冲归一化坐标。
        // 相机画面是 aspectFill 摆放的，可能比视图还大，所以必须按 display 换算，
        // 不能直接除以视图宽高（那样点偏了会识别到别处）。
        let nx = (location.x - display.minX) / display.width
        let ny = (location.y - display.minY) / display.height
        guard (0...1).contains(nx), (0...1).contains(ny) else { return }

        aimPoint = CGPoint(x: nx, y: ny)
        Haptics.selection()
        showFeedback("只识别框内那块")
    }

    // MARK: - 底栏

    private var bottomBar: some View {
        HStack(spacing: 26) {
            Button {
                controller.toggleTorch()
                Haptics.selection()
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: controller.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.title3)
                        .frame(width: 56, height: 56)
                        .artGlassCircle()
                    Text("手电筒").font(.caption2)
                }
            }
            .tint(controller.isTorchOn ? Theme.accent : .white)
            .disabled(!controller.isTorchAvailable)
            .opacity(controller.isTorchAvailable ? 1 : 0.4)

            if mode == .text {
                Button {
                    zoom = zoom == 1 ? 2 : (zoom == 2 ? 3 : 1)
                    Haptics.selection()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "plus.magnifyingglass")
                            .font(.title3)
                            .frame(width: 56, height: 56)
                            .artGlassCircle()
                        Text(zoom == 1 ? "放大" : "\(zoom)×").font(.caption2)
                    }
                }
                .tint(zoom > 1 ? Theme.accent : .white)

                Button {
                    profile = profile == .dotMatrix ? .none : .dotMatrix
                    profileIsManual = true
                    Haptics.selection()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "dot.squareshape.split.2x2")
                            .font(.title3)
                            .frame(width: 56, height: 56)
                            .artGlassCircle()
                        Text("喷码").font(.caption2)
                    }
                }
                .tint(profile == .dotMatrix ? Theme.accent : .white)

                // 竖排的喷码必须先转正，不然再怎么预处理也读不出来
                Button {
                    rotationDegrees = rotationDegrees == 0 ? 90 : (rotationDegrees == 90 ? 270 : 0)
                    Haptics.selection()
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "rotate.right")
                            .font(.title3)
                            .frame(width: 56, height: 56)
                            .artGlassCircle()
                        Text(rotationDegrees == 0 ? "转正" : "\(rotationDegrees)°")
                            .font(.caption2)
                    }
                }
                .tint(rotationDegrees != 0 ? Theme.accent : .white)
            }

            Button {
                isShowingManualEntry = true
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "keyboard")
                        .font(.title3)
                        .frame(width: 56, height: 56)
                        .artGlassCircle()
                    Text("手输编号").font(.caption2)
                }
            }
            .tint(.white)
        }
        .padding(.top, 14)
    }

    // MARK: - 相机不可用

    private var cameraFallback: some View {
        VStack(spacing: 20) {
            Image(systemName: controller.authorization.symbolName)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.white.opacity(0.75))

            Text(controller.captureError
                 ?? RuntimeEnvironment.cameraGuidance(
                        authorizationDenied: controller.authorization == .denied))
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)

            if controller.authorization == .denied {
                Button(RuntimeEnvironment.isLiveContainer ? "打开系统设置（给 LiveContainer 开相机）" : "打开系统设置") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .artGlassButton()
            }

            // 相机不可用时，手工输入就是主线，给它最大的按钮。
            Button {
                isShowingManualEntry = true
            } label: {
                Label("手动输入编号", systemImage: "keyboard")
                    .frame(minWidth: 220)
            }
            .artProminentButton()
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
    }

    // MARK: - 认字处理

    private func handleFrame(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        guard mode == .text, !isPaused, controller.authorization == .authorized else { return }
        guard !ocr.isBusy else { return }

        // 自动挑预处理档位。
        //
        // 让用户自己去分辨"普通印刷体"和"点阵喷码"是不现实的 ——
        // 他不知道区别，也不知道该点哪个按钮。所以这里替他看一眼：
        // 等画面稳几帧，用笔画里的短横段占比判断像不像点阵，
        // 像就自动切到喷码档位并告诉他一声。
        bufferSize = CGSize(
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer)
        )
        framesSeen += 1
        if !profileIsManual, !didAutoDetectProfile, framesSeen == 3 {
            didAutoDetectProfile = true
            let suggested = ocr.suggestProfile(for: buffer)
            if suggested != profile {
                profile = suggested
                showFeedback(suggested == .dotMatrix
                             ? "像是点阵喷码，已切到喷码模式"
                             : "已切到普通印刷体模式")
            }
        }

        Task { @MainActor in
            let lines = await ocr.recognize(
                pixelBuffer: buffer,
                orientation: orientation,
                profile: profile,
                zoom: zoom,
                roi: aimRect,
                rotationDegrees: rotationDegrees
            )
            guard !lines.isEmpty else { return }
            let draft = PaintLabelParser.parse(lines: lines, known: knownColors())
            guard draft.hasColor else { return }

            // 防抖：连续两次读到同一个颜色名才显示。
            // 不加这个，屏幕上的字会一直跳 —— 一帧一个候选，根本没法按按钮。
            if draft.suggestedName == pendingName {
                pendingHits += 1
                if pendingHits >= 2 {
                    withAnimation(.snappy(duration: 0.25)) { labelDraft = draft }
                }
            } else {
                pendingName = draft.suggestedName
                pendingHits = 1
            }
        }
    }

    private func resetReading() {
        withAnimation(.snappy(duration: 0.2)) { labelDraft = nil }
        pendingName = nil
        pendingHits = 0
        // 让自动判断可以再跑一次（画面变了，档位可能也该变）
        didAutoDetectProfile = false
        framesSeen = 0
    }

    /// 颜色库 + 预设置合成"已知颜色"，给认字结果做匹配。
    ///
    /// 颜色库优先 —— 用户可能自己改过名字或色值，那才是他认可的那一份。
    private func knownColors() -> [KnownLabelColor] {
        var result: [KnownLabelColor] = []
        var seen = Set<String>()

        for color in PaletteService.allColors(in: context) {
            result.append(KnownLabelColor(
                code: color.code, name: color.name, ciCode: color.ciCode, hex: color.hex
            ))
            seen.insert(color.code)
        }
        for preset in PresetColors.standard42 {
            let code = PresetColors.code(forIndex: preset.index)
            guard !seen.contains(code) else { continue }
            result.append(KnownLabelColor(
                code: code, name: preset.name, ciCode: preset.ciCode, hex: preset.hex
            ))
        }
        return result
    }

    /// 用户点了「就是它」。
    private func acceptLabel(_ draft: PaintLabelDraft) {
        let target = resolveColor(from: draft)
        guard let color = target else {
            showFeedback("没认出颜色名，换「手输编号」或者把镜头再靠近一点")
            Haptics.scanDuplicate()
            return
        }

        Haptics.scanSuccess()
        if let well = PaletteService.wellHolding(color, in: context) {
            // 已经装在某一格 —— 直接打开那一格的编辑页，改余量就行。
            acceptedCount += 1
            showFeedback("「\(color.name)」在 \(well.positionLabel) 格")
            editingWell = well
        } else if let well = PaletteService.firstEmptyWell(in: context) {
            PaletteService.assign(color, to: well, in: context)
            acceptedCount += 1
            showFeedback("已装进 \(well.positionLabel) 格")
            editingWell = well
        } else {
            acceptedCount += 1
            showFeedback("已存入颜色库（盒子里没有空格了）")
        }
        labelDraft = nil
    }

    /// 把认字结果落成颜色库里的一条记录（必要时新建）。
    private func resolveColor(from draft: PaintLabelDraft) -> PaintColor? {
        // 1) 匹配到已知颜色 → 直接用
        if let code = draft.matchedCode, let existing = PaletteService.color(code: code, in: context) {
            return existing
        }

        // 2) 没匹配到，但读出了名字 → 新建
        let name = draft.suggestedName
        guard !name.isEmpty else { return nil }

        // 先按名字找一遍 —— 用户可能上次已经手建过同名的颜色了。
        if let byName = PaletteService.allColors(in: context).first(where: { $0.name == name }) {
            return byName
        }

        let code = draft.suggestedCode.isEmpty
            ? "OCR-\(Int(Date.now.timeIntervalSince1970))"
            : draft.suggestedCode

        return PaletteService.upsertColor(
            code: code,
            name: name,
            series: draft.brand == nil ? "认字入库" : "",
            hex: draft.suggestedHex ?? "#8E8E93",
            ciCode: draft.ciCode,
            scannedPayload: draft.rawText,
            in: context
        )
    }

    // MARK: - 扫码处理

    private func handle(payload: String, symbologyRaw: String, isManual: Bool) {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !isManual {
            // 同一载荷 2.5 秒内只接受一次
            let now = Date.now
            if let last = recentPayloads[trimmed], now.timeIntervalSince(last) < 2.5 { return }
            if recentPayloads.count > 64 {
                recentPayloads = recentPayloads.filter { now.timeIntervalSince($0.value) < 10 }
            }
            recentPayloads[trimmed] = now
        }

        let draft = PaintScanParser.parse(payload: trimmed, symbologyRaw: symbologyRaw)

        // 已经入库过的码。
        //
        // ⚠️ 这里以前是直接 return —— 于是**第二个颜色永远进不来**。
        // 真实反馈就是踩在这个上：不同颜色的条码都一样，扫第二支时撞上唯一约束，
        // 界面只说一句"已经在颜色库里了"，然后就没了。
        // 现在改成讲清楚原因 + 给出两条出路。
        if let existing = PaletteService.color(code: draft.code, in: context) {
            Haptics.scanDuplicate()
            if draft.payloadMayBeShared || ScanSymbology.isRetailBarcode(symbologyRaw) {
                sharedCodeDraft = draft
            } else {
                showFeedback("「\(existing.name)」已经在颜色库里了")
            }
            return
        }

        Haptics.scanSuccess()
        reviewDraft = draft
    }

    private func showFeedback(_ text: String) {
        withAnimation(.snappy(duration: 0.25)) { feedback = text }
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            withAnimation(.snappy(duration: 0.25)) { feedback = nil }
        }
    }
}

// MARK: - 共用条码说明

/// 「这个条码已经属于别的颜色了」。
///
/// 这不是错误，是中国颜料包装的常态：同一批不同颜色共用一条码。
/// 所以这个面板的任务是**解释 + 给出路**，而不是拦着不让走。
struct SharedBarcodeSheet: View {

    enum Action {
        case useText
        case nameIt
    }

    let draft: PaintColorDraft
    var onChoose: (Action) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var colors: [PaintColor]

    /// 这个码现在挂在哪些颜色上。
    private var owners: [PaintColor] {
        colors.filter { $0.scannedPayload == draft.rawPayload || $0.code == draft.code }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("这个条码已经用过了", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)

                        Text("同一批不同颜色的条码经常是共用的，所以条码认不出颜色。")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()

                    if !owners.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(title: "这个码现在挂在")
                            ForEach(owners) { color in
                                HStack(spacing: 10) {
                                    ColorDot(hex: color.hex, size: 24)
                                    Text(color.name).font(.subheadline)
                                    Spacer()
                                    Text(color.code)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle()
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            onChoose(.useText)
                            dismiss()
                        } label: {
                            Label("改用「认字」识别颜色名", systemImage: "text.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .artProminentButton()
                        .controlSize(.large)

                        Button {
                            onChoose(.nameIt)
                            dismiss()
                        } label: {
                            Label("我知道是什么颜色，手动建一条", systemImage: "square.and.pencil")
                                .frame(maxWidth: .infinity)
                        }
                        .artGlassButton()
                        .controlSize(.large)

                        Text("手动建的那条会**用颜色名当色号**（而不是用条码），"
                             + "这样同一批里别的颜色也能各建各的，不会互相顶掉。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle()
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .artScrollEdgeEffect()
            .navigationTitle("条码被共用了")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("知道了") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 读到了什么

/// 把 OCR 的原始输出摊开给用户看。
///
/// 这样"为什么没认出来"是**看得见**的：可能是字太小、可能是角度歪了、
/// 也可能它确实读到了、只是没匹配上颜色库。
struct RawTextSheet: View {

    let draft: PaintLabelDraft?
    let service: LabelOCRService

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("识别次数", value: "\(service.recognitionCount)")
                    LabeledContent("可用语言", value: service.languages.isEmpty
                                   ? "系统默认" : service.languages.joined(separator: "、"))
                    if let error = service.lastError {
                        LabeledContent("错误", value: error)
                    }
                } header: {
                    Text("识别状态")
                } footer: {
                    Text("识别完全在本机完成，不联网、不上传。")
                }

                if let draft, !draft.lines.isEmpty {
                    Section("读到的文字（按行）") {
                        ForEach(Array(draft.lines.enumerated()), id: \.offset) { _, line in
                            HStack {
                                Text(line.text)
                                Spacer()
                                Text("\(Int(line.confidence * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }

                    Section("推断结果") {
                        LabeledContent("颜色名", value: draft.suggestedName.isEmpty ? "—" : draft.suggestedName)
                        LabeledContent("颜料标准号", value: draft.ciCode ?? "—")
                        LabeledContent("色号", value: draft.productCode ?? "—")
                        LabeledContent("品牌", value: draft.brand ?? "—")
                        LabeledContent("匹配方式", value: draft.matchKind.displayName)
                        LabeledContent("置信度", value: "\(Int(draft.confidence * 100))%")
                    }

                    if !draft.warnings.isEmpty {
                        Section("提示") {
                            ForEach(draft.warnings, id: \.self) { warning in
                                Text(warning)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                } else {
                    Section {
                        Text("还没读到任何文字。把镜头对准包装上印字的地方，"
                             + "让字占满取景框中间，光线足一点。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("它读到了什么")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("好") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 结果面板

struct ScanResultSheet: View {

    let draft: PaintColorDraft
    /// 参数表示是否顺带装进了格子。
    var onSaved: (Bool) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(sort: \PaletteBox.createdAt) private var boxes: [PaletteBox]

    @State private var name: String
    @State private var brand: String
    @State private var series: String
    @State private var hex: String
    @State private var alsoAssign = true

    init(draft: PaintColorDraft, onSaved: @escaping (Bool) -> Void) {
        self.draft = draft
        self.onSaved = onSaved
        _name = State(initialValue: draft.name ?? "")
        _brand = State(initialValue: draft.brand ?? "")
        _series = State(initialValue: draft.series ?? "")
        _hex = State(initialValue: draft.hex ?? "#2E5BFF")
    }

    private var firstEmptyWell: PaletteWell? {
        boxes.first?.orderedWells.first { $0.color == nil }
    }

    private var canSave: Bool {
        if draft.payloadMayBeShared { return !name.isBlank }
        return !draft.code.isBlank && !name.isBlank
    }

    /// 颜色库里已经有一条同名颜色 —— 那就复用它，不要建重名的第二条。
    private var sameNameColor: PaintColor? {
        let trimmed = name.trimmed
        guard !trimmed.isEmpty else { return nil }
        let colors = (try? context.fetch(FetchDescriptor<PaintColor>())) ?? []
        return colors.first { $0.name == trimmed }
    }

    /// 最终用的色号。
    ///
    /// 条码可能被多个颜色共用时，**绝不能用条码当色号** —— 否则第二条就撞唯一约束。
    /// 改用颜色名生成，这样同一批里每个颜色各有一条。
    private var resolvedCode: String {
        if let sameNameColor { return sameNameColor.code }
        if draft.payloadMayBeShared { return draft.nameBasedCode(name) }
        return draft.code
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(hex: hex) ?? Theme.emptyWellFill)
                        }
                        .frame(width: 68, height: 68)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(draft.symbologyName)
                                .font(.subheadline.weight(.medium))
                            Text(draft.qualitySummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if draft.payloadMayBeShared {
                    Section {
                        Label {
                            Text("这个条码可能被多个颜色共用，所以**不拿它当色号** —— "
                                 + "会用颜色名当身份，同一批里每个颜色各建一条。")
                                .font(.caption)
                        } icon: {
                            Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                        }
                    }
                } else {
                    Section {
                        LabeledContent("编号") {
                            Text(draft.code)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    } header: {
                        Text("扫到的编号")
                    } footer: {
                        Text(draft.source.automationHint)
                    }
                }

                Section("颜色信息") {
                    LabeledContent("颜色名") {
                        TextField("如「群青」", text: $name)
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("颜色值") {
                        HStack(spacing: 10) {
                            ColorPicker("", selection: Binding(
                                get: { Color(hex: hex) ?? .blue },
                                set: { hex = $0.toHex() ?? hex }
                            ), supportsOpacity: false)
                            .labelsHidden()
                            TextField("#RRGGBB", text: $hex)
                                .font(.system(.body, design: .monospaced))
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                        }
                    }

                    LabeledContent("品牌") {
                        TextField("选填", text: $brand)
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("系列") {
                        TextField("选填，如「艺术家级」", text: $series)
                            .multilineTextAlignment(.trailing)
                    }
                }

                if let sameNameColor {
                    Section {
                        HStack(spacing: 10) {
                            ColorDot(hex: sameNameColor.hex, size: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("颜色库里已经有「\(sameNameColor.name)」")
                                    .font(.subheadline)
                                Text("会直接用它（色号 \(sameNameColor.code)），不会建重名的第二条。")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else {
                    Section {
                        LabeledContent("入库色号") {
                            Text(resolvedCode)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("将要新建")
                    }
                }

                if let well = firstEmptyWell {
                    Section {
                        Toggle("顺便装进第 \(well.positionLabel) 格", isOn: $alsoAssign)
                    } footer: {
                        Text("第 \(well.positionLabel) 格是当前第一个空格子。")
                    }
                } else {
                    Section {
                        Label("盒子里已经没有空格了，只入库不装格", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !draft.warnings.isEmpty {
                    Section("提示") {
                        ForEach(draft.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("入库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("放弃") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("入库") { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
    }

    private func save() {
        // 同名颜色已经存在就复用它 —— 这是"条码共用"场景下最要紧的一条：
        // 用户扫了第二支、输入「群青」，应该落到预设那条 PRESET-35 上，
        // 而不是再建一个重名的「群青」。
        let color: PaintColor
        if let sameNameColor {
            color = sameNameColor
        } else {
            color = PaletteService.upsertColor(
                code: resolvedCode,
                name: name.trimmed,
                brand: brand.trimmed,
                series: series.trimmed,
                hex: hex.trimmed,
                scannedPayload: draft.rawPayload,
                in: context
            )
        }

        var assigned = false
        if alsoAssign, let well = firstEmptyWell {
            PaletteService.assign(color, to: well, in: context)
            assigned = true
        }

        Haptics.saved()
        onSaved(assigned)
        dismiss()
    }
}
