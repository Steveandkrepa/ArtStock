//
//  RuntimeEnvironment.swift
//  ArtAssist — 美术生的工具箱
//
//  运行环境探测。
//
//  ── 为什么需要它 ─────────────────────────────────────────────
//  这个 App 可能被装在 **LiveContainer** 里运行（一个把 App 加载进自己进程的启动器）。
//  LiveContainer 的 README「Limitations」写得很明确：
//
//      · Entitlements from the guest app are not applied to the host app.
//      · **App Permissions are globally applied.**
//
//  也就是说：**权限属于 LiveContainer 本体，不属于被装进去的 App。**
//  本 App 的 Info.plist 里那行 NSCameraUsageDescription 在这个环境里根本不起作用 ——
//  决定 TCC 弹窗的是宿主的信息。
//
//  所以相机在这个环境里很可能拿不到。这时不该给用户看一个"相机不可用"的
//  干巴巴提示，而应该直接告诉他**该去哪里开权限**（iOS 设置 → LiveContainer → 相机），
//  并且把手工输入编号这条路摆到最前面。
//
//  ── 探测方式 ─────────────────────────────────────────────────
//  扫 dyld 已加载的镜像名。LiveContainer 的文档里有一条兼容性开关叫
//  "Hide LiveContainer from Dyld API" —— 说明默认情况下它在 dyld 层面是可见的。
//  用户若开了那个开关，这里就会探测失败；所以这只是**尽力而为的提示增强**，
//  相机不可用的降级流程本身不依赖它。
//

import Foundation
// _dyld_image_count / _dyld_get_image_name 来自这个模块，
// 只 import Foundation 是拿不到的（实测编译报 cannot find in scope）。
import MachO

enum RuntimeEnvironment {

    /// 是否运行在 LiveContainer 内。
    ///
    /// 用 dyld 已加载镜像名判断。这是尽力而为的探测：
    /// LiveContainer 提供了 "Hide LiveContainer from Dyld API" 开关可以隐藏自己。
    /// 所以**不要**把关键逻辑建立在这个结果上，只用它来改善提示文案。
    static let isLiveContainer: Bool = {
        // 先看环境变量（LiveContainer 会注入一些自己的标记）
        let environment = ProcessInfo.processInfo.environment
        if environment.keys.contains(where: { $0.localizedCaseInsensitiveContains("livecontainer") }) {
            return true
        }

        // 再扫 dyld 镜像
        guard let images = loadedImagePaths() else { return false }
        return images.contains { $0.localizedCaseInsensitiveContains("LiveContainer") }
    }()

    /// 当前进程加载的全部镜像路径。
    private static func loadedImagePaths() -> [String]? {
        let count = _dyld_image_count()
        guard count > 0 else { return nil }
        var paths: [String] = []
        paths.reserveCapacity(Int(count))
        for index in 0..<count {
            guard let name = _dyld_get_image_name(index) else { continue }
            paths.append(String(cString: name))
        }
        return paths
    }

    /// 相机不可用时，给用户的一段可操作说明。
    ///
    /// 环境不同，答案完全不同：在 LiveContainer 里要去给 **LiveContainer** 开权限，
    /// 而不是给这个 App —— 这一点如果不说清楚，用户会一直在这里找开关。
    static func cameraGuidance(authorizationDenied: Bool) -> String {
        if isLiveContainer {
            return """
            LiveContainer 里权限属于容器本身，本 App 申请不到相机。

            系统「设置」→ LiveContainer → 相机

            找不到「相机」这一项，就先用容器里任意一个用相机的 App 触发一次授权。
"""
        }
        if authorizationDenied {
            return "已拒绝相机访问。请到「设置 → ArtAssist」中开启相机权限，或改用手动输入编号。"
        }
        return "当前环境没有可用摄像头。可以用下面的「手动输入编号」，功能不受影响。"
    }
}
