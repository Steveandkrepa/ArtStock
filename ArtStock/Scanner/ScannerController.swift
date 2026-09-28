//
//  ScannerController.swift
//  ArtAssist — 美术生的工具箱
//
//  相机状态的可观察外壳。
//  UIViewController 不适合直接被 SwiftUI 观察，所以把"状态"和"控制通道"
//  抽到这里：VC 往这里写状态，SwiftUI 从这里下发指令。
//

import Foundation
import Observation

/// 相机授权状态（把 AVFoundation 的多个 case 归并成界面真正要区分的几种）。
enum CameraAuthorization: Equatable {
    /// 尚未询问。
    case unknown
    /// 已授权。
    case authorized
    /// 用户拒绝或系统策略限制，需要去设置里开。
    case denied
    /// 设备根本没有可用摄像头（模拟器就是这种情况）。
    case unavailable

    var isUsable: Bool { self == .authorized }

    var guidance: String {
        switch self {
        case .unknown: return "正在请求相机权限…"
        case .authorized: return "将二维码对准取景框"
        case .denied: return "已拒绝相机访问。请到「设置 → ArtStock」中开启相机权限，或改用手工输入编码。"
        case .unavailable: return "当前设备没有可用摄像头。模拟器无法扫码，请用真机，或改用手工输入编码。"
        }
    }

    var symbolName: String {
        switch self {
        case .unknown: return "hourglass"
        case .authorized: return "qrcode.viewfinder"
        case .denied: return "lock.fill"
        case .unavailable: return "video.slash.fill"
        }
    }
}

/// 相机控制器。
@MainActor
@Observable
final class ScannerController {

    // MARK: - 由 VC 写入的状态

    var authorization: CameraAuthorization = .unknown
    var isRunning: Bool = false
    var isTorchOn: Bool = false
    var isTorchAvailable: Bool = false
    /// 会话配置失败时的原因（例如被其它 App 占用）。
    var captureError: String?

    // MARK: - 指令通道（由 VC 注册）

    /// 请求切换手电筒。
    @ObservationIgnored var toggleTorchAction: (() -> Void)?
    /// 请求启动会话。
    @ObservationIgnored var startAction: (() -> Void)?
    /// 请求停止会话（进后台或离开扫码页时省电）。
    @ObservationIgnored var stopAction: (() -> Void)?

    func toggleTorch() {
        guard isTorchAvailable else { return }
        toggleTorchAction?()
    }

    func start() {
        startAction?()
    }

    func stop() {
        stopAction?()
    }

    /// 会话是否处于可用状态（授权通过且没有捕获错误）。
    var isSessionUsable: Bool {
        authorization.isUsable && captureError == nil
    }
}
