//
//  Haptics.swift
//  ArtAssist — 美术生的工具箱
//
//  触觉与音效反馈。扫码是高频动作，没有反馈用户会反复扫同一个码。
//

import AudioToolbox
import UIKit

@MainActor
enum Haptics {

    /// 扫码成功识别。
    static func scanSuccess() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    /// 扫到已存在的码。
    static func scanDuplicate() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
    }

    /// 识别失败。
    static func scanFailure() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
    }

    /// 建档完成。
    static func saved() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
    }

    /// 轻量选择反馈（切换数量、切换筛选）。
    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
    }

    /// 余量告警级别的强反馈。
    static func alert() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
        AudioServicesPlaySystemSound(1053)
    }
}
