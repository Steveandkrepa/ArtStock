//
//  ArtStockStore.swift
//  ArtAssist — 美术生的工具箱
//
//  持久化容器工厂。
//
//  重要设计约束（针对 SideStore / 免费 Apple ID 自签名）：
//    · 不使用 CloudKit —— 免费账号没有 iCloud 能力，声明了会导致签名后启动即崩。
//    · 不使用 App Group —— 同理需要 entitlement。
//    · 因此这里把 cloudKitDatabase 与 groupContainer 都显式设为"无"，
//      让 SwiftData 只写 App 沙盒内的本地 SQLite 文件。
//

import Foundation
import SwiftData

/// 启动结果。把"是否降级"作为返回值传递，避免引入可变的全局状态。
struct ArtStockBootstrap {
    let container: ModelContainer
    /// 非 nil 表示磁盘库打开失败、当前跑在内存库上（进程退出即丢数据）。
    let degradedReason: String?

    var isDegraded: Bool { degradedReason != nil }
}

/// 本地数据文件的状态。降级时用它告诉用户"数据其实还在"。
struct LocalStoreFileInfo {
    var path: String
    var exists: Bool
    var byteCount: Int64

    var sizeText: String { TextbookFormat.bytes(byteCount) }
}

enum ArtStockStore {

    /// 全量模型清单。新增 @Model 后必须登记到这里，否则不会被建表。
    static let schema = Schema([
        // 颜料盒：一盒 + 若干格子
        PaletteBox.self,
        PaletteWell.self,
        // 颜色库与补充装
        PaintColor.self,
        RefillStock.self,
        RefillEvent.self,
        // 颜料之外的其他耗材
        SupplyItem.self,
        // 保湿计时
        WetnessSession.self,
        // 教材（搜索来的书 + 每一页的下载状态）
        Textbook.self,
        TextbookPage.self,
        // 待收包裹（下单记录 → 到货 → 一键入库）
        IncomingPackage.self,
        IncomingPackageItem.self
    ])

    // MARK: - 配置

    /// 本地磁盘配置。
    static var localConfiguration: ModelConfiguration {
        ModelConfiguration(
            "ArtStock",
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
    }

    /// 内存配置，供预览与降级使用。
    static var memoryConfiguration: ModelConfiguration {
        ModelConfiguration(
            "ArtStockMemory",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
    }

    // MARK: - 启动

    /// 创建正式容器。
    ///
    /// 数据文件损坏或模型不兼容时**不会崩溃**，而是降级到内存库并回报原因，
    /// 让界面提示用户到设置里重置数据库。
    static func bootstrap() -> ArtStockBootstrap {
        do {
            let container = try ModelContainer(for: schema, configurations: [localConfiguration])
            return ArtStockBootstrap(container: container, degradedReason: nil)
        } catch {
            // ⚠️ 走到这里通常意味着**模型和已有数据不兼容**（最常见的原因：
            //    给 @Model 加了"非可选且无默认值"的新字段，轻量迁移做不了）。
            //
            //    注意：**这里不会删除任何文件。** 磁盘上的 ArtStock.store 原样保留，
            //    所以修好模型之后数据会自己回来。降级只是为了不崩，
            //    但它是"数据看起来丢了"的唯一原因 —— 所以必须让界面大声说出来。
            //
            //    真实事故：SupplyItem.recentUnitsRaw 就是这么加进去的，
            //    用户看到的是"装完新版本数据全丢、预设也重新乱掉"。
            if let memory = try? ModelContainer(for: schema, configurations: [memoryConfiguration]) {
                return ArtStockBootstrap(
                    container: memory,
                    degradedReason: error.localizedDescription
                )
            }
            // 连内存库都建不起来说明模型定义本身有问题，属于开发期错误。
            fatalError("无法创建 ArtStock 数据容器：\(error)")
        }
    }

    // MARK: - 重置

    /// 本地 store 文件的状态。
    ///
    /// 用途很具体：降级到内存库时，用户看到的是"数据全没了"，
    /// 但**文件其实好好地在磁盘上**。把路径与大小显示出来，
    /// 他就能确认数据没被删 —— 这比一句"打开失败"有用得多。
    static func localStoreFileInfo() -> LocalStoreFileInfo? {
        let fileManager = FileManager.default
        guard let supportURL = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }

        let url = supportURL.appendingPathComponent("ArtStock.store")
        let exists = fileManager.fileExists(atPath: url.path)
        // resourceValues 的 fileSize 已经是 Int?，try? 之后不该再 ?? 0（编译器会警告多余）
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return LocalStoreFileInfo(path: url.path, exists: exists, byteCount: Int64(size ?? 0))
    }

    /// 删除磁盘上的数据文件，用于设置页的"清空并重建数据库"。
    /// - Returns: 是否全部删除干净（文件本来就不存在也算成功）。
    @discardableResult
    static func destroyLocalStore() -> Bool {
        let fileManager = FileManager.default
        guard let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return false
        }

        // SwiftData 默认把 store 放在 Application Support 下，文件名与 ModelConfiguration 名称一致。
        let candidates = [
            "ArtStock.store", "ArtStock.store-shm", "ArtStock.store-wal",
            "default.store", "default.store-shm", "default.store-wal"
        ]

        var succeeded = true
        for name in candidates {
            let url = supportURL.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }
}
