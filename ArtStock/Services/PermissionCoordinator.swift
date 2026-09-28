//
//  PermissionCoordinator.swift
//  ArtAssist — 美术生的工具箱
//
//  权限的统一入口：查询状态 + 主动申请。
//
//  ── 为什么要单独做这件事 ─────────────────────────────────────
//  早先版本把相机权限申请**写在扫码页的视图控制器里**，而那个控制器
//  又只在"已授权"时才被创建 —— 形成一个死循环：
//      未授权 → 不创建控制器 → 不申请 → 永远未授权
//  结果相机在任何环境下都用不了（不只是 LiveContainer）。
//
//  正确做法是**启动时主动申请**，跟其他 App 一样：
//  权限弹窗本来就是"首次打开时问一次"的东西，不该等到用户点进某个页面。
//
//  ── 关于 LiveContainer ───────────────────────────────────────
//  在 LiveContainer 里，弹窗归属于 LiveContainer 本体，而且权限是全局的
//  （官方 README：App Permissions are globally applied）。
//  但这不影响"申请"这个动作本身 —— 只要调用 requestAccess，
//  弹窗照样会出来，用户同意后就能用。
//  所以这个 App 和其他 App 一样，开机就申请。
//

import AVFoundation
import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class PermissionCoordinator {

    private(set) var cameraStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var isRequesting = false

    /// 首次启动的引导页是否已经走过。
    private static let onboardingKey = "hasCompletedPermissionOnboarding"

    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: Self.onboardingKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.onboardingKey) }
    }

    /// 是否还有值得引导申请的权限（从没问过的）。
    var needsOnboarding: Bool {
        !hasCompletedOnboarding && (cameraStatus == .notDetermined || notificationStatus == .notDetermined)
    }

    // MARK: - 状态

    func refresh() async {
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        notificationStatus = await NotificationService.authorizationStatus()
    }

    var cameraGranted: Bool { cameraStatus == .authorized }

    // MARK: - 申请

    /// 申请相机权限。
    ///
    /// 关键：无论授权状态如何都可以调用；只有 `.notDetermined` 会真正弹窗，
    /// 其余情况直接返回当前结果，不会打扰用户。
    @discardableResult
    func requestCamera() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraStatus = .authorized
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            return granted
        case .denied, .restricted:
            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            return false
        @unknown default:
            return false
        }
    }

    /// 申请通知权限。
    @discardableResult
    func requestNotifications() async -> Bool {
        let granted = await NotificationService.ensureAuthorized()
        await refresh()
        return granted
    }

    /// 依次申请相机与通知。引导页与设置页都用它。
    func requestAll() async {
        isRequesting = true
        defer { isRequesting = false }

        // 顺序很重要：相机先问。两个弹窗连着弹时，
        // 第二个会排队等第一个处理完 —— 这是系统行为，不是 bug。
        _ = await requestCamera()
        _ = await requestNotifications()
        await refresh()
    }

    /// 标记引导已完成。
    func completeOnboarding() {
        hasCompletedOnboarding = true
    }
}
