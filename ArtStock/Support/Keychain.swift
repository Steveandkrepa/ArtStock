//
//  Keychain.swift
//  ArtAssist — 美术生的工具箱
//
//  登录凭证存 Keychain，不存明文文件。
//
//  ── 为什么要改掉原来的做法 ───────────────────────────────────
//  原来的 Python 脚本把 token 写在 `dxart_token.txt` 里（明文）。
//  在这个 App 里如果照搬，会有一个很具体的问题：
//  App 沙盒里的普通文件**会进 iTunes / iCloud 备份**，
//  等于把登录凭证一起备份到别的地方去了。
//
//  Keychain 的条目不进普通文件备份，而且可以指定
//  `kSecAttrAccessibleAfterFirstUnlock` —— 设备解锁过一次之后才可读，
//  锁屏状态下别人拿到设备也读不到。
//
//  ── 为什么不用第三方封装 ─────────────────────────────────────
//  这里只需要"存一个字符串、读一个字符串、删掉"三件事，
//  Security 框架的 C API 直接调就够了。引一个依赖来处理三个函数不划算。
//

import Foundation
import Security

enum Keychain {

    /// 服务名。用 bundle id 前缀，避免和别的 App 撞。
    private static let service = "com.yuanjunhao.artstock.dxart"

    /// DXArt 登录 token 的 key。
    static let dxartTokenKey = "dxart.token"
    /// 记住的手机号（不是密码，只是省一次输入）。
    static let dxartPhoneKey = "dxart.phone"

    // MARK: - 写

    @discardableResult
    static func save(_ value: String, for key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // 先删再加：SecItemUpdate 在条目不存在时会失败，
        // 而"删掉旧的重写"在任何状态下都能成功。
        delete(key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            // 设备解锁过一次之后才可读 —— 比默认的 Always 安全，
            // 又不会像 WhenUnlocked 那样在后台下载时读不到。
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - 读

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    // MARK: - 删

    @discardableResult
    static func delete(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        // 本来就没有也算成功
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// 退出登录：凭证和记住的手机号一起清掉。
    static func clearDXArtCredentials() {
        delete(dxartTokenKey)
        delete(dxartPhoneKey)
    }
}
