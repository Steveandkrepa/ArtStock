//
//  TextbookStorage.swift
//  ArtAssist — 美术生的工具箱
//
//  教材文件的落盘规则：目录、文件名、安全化。
//
//  ── 为什么文件名要单独写一层 ─────────────────────────────────
//  原 Python 脚本用书名当目录名：
//      "".join(c for c in book_name if c not in r'\/:*?"<>|')
//  这行有三个问题，在真机上都会变成实际麻烦：
//
//    · **长度没限制**。iOS 文件名的上限是 255 个 UTF-8 字节，
//      而中文一个字就 3 字节 —— 书名超过 80 来个字就写不进去，
//      报错还是难懂的 Cocoa error 63。教材名经常很长。
//    · **控制字符没滤**。书名里夹换行/制表符的话，目录名会很难看。
//    · **首尾的点与空格没处理**。以点开头的目录在 iOS 上虽然能用，
//      但容易和隐藏文件混淆；末尾空格在不同文件系统上行为不一致。
//
//  另外书名相同但 id 不同的两本书会**互相覆盖**目录 —— 这是数据丢失。
//  所以目录名一定带 id。
//
//  这个文件里安全化与路径拼装的部分是纯函数，可以在 macOS 上测。
//

import Foundation
import CryptoKit

enum TextbookStorage {

    /// 每页一张图。用固定宽度补零，保证字典序 = 页码序。
    static func fileName(forPage page: Int) -> String {
        String(format: "%04d.jpg", max(1, page))
    }

    /// 把所有页图放在这个子目录里，方便整本删。
    static let pagesDirectoryName = "pages"

    /// Apple Pencil 批注的存放目录。
    ///
    /// 单独一个目录而不是塞进 SwiftData：
    ///   · `PKDrawing.dataRepresentation()` 动辄几十 KB，几百页就是十几 MB，
    ///     放进数据库会让每次 fetch 都背着它
    ///   · 删书时跟着目录一起删掉，不用维护关系
    ///   · 路径是**可推导的**（`drawings/0007.drawing`），
    ///     所以不需要在页记录里再加一个字段，也就没有 schema 迁移
    static let drawingsDirectoryName = "drawings"

    /// 教材根目录（Application Support/Textbooks）。
    ///
    /// 放 Application Support 而不是 Documents：
    /// Documents 会被"文件"App 暴露出来，也会进 iCloud 备份 ——
    /// 教材原图几百 MB，备份上去不合适。
    static func rootDirectory() -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return nil }
        return base.appendingPathComponent("Textbooks", isDirectory: true)
    }

    /// 某本书的目录：`<id>-<安全书名>/`
    static func bookDirectory(remoteID: Int, name: String) -> URL? {
        guard let root = rootDirectory() else { return nil }
        return root.appendingPathComponent(bookFolderName(remoteID: remoteID, name: name),
                                          isDirectory: true)
    }

    /// 某本书的页图目录。
    static func pagesDirectory(remoteID: Int, name: String) -> URL? {
        bookDirectory(remoteID: remoteID, name: name)?
            .appendingPathComponent(pagesDirectoryName, isDirectory: true)
    }

    /// 某页的完整路径。
    static func pageURL(remoteID: Int, name: String, page: Int) -> URL? {
        pagesDirectory(remoteID: remoteID, name: name)?
            .appendingPathComponent(fileName(forPage: page))
    }

    /// 某页相对于"书目录"的路径 —— 存进 SwiftData 用这个，
    /// 不存绝对路径（应用沙盒路径在重装/更新后会变，存绝对路径会全部失效）。
    static func relativePagePath(page: Int) -> String {
        "\(pagesDirectoryName)/\(fileName(forPage: page))"
    }

    /// 封面缓存文件名。
    static let coverFileName = "cover.img"

    /// 封面文件路径。
    static func coverURL(remoteID: Int, name: String) -> URL? {
        bookDirectory(remoteID: remoteID, name: name)?
            .appendingPathComponent(coverFileName)
    }

    // MARK: 批注

    /// 某页批注的完整路径。
    static func drawingURL(remoteID: Int, name: String, page: Int) -> URL? {
        bookDirectory(remoteID: remoteID, name: name)?
            .appendingPathComponent(drawingsDirectoryName, isDirectory: true)
            .appendingPathComponent(drawingFileName(forPage: page))
    }

    /// 批注文件名。跟页图同号，方便对照。
    static func drawingFileName(forPage page: Int) -> String {
        String(format: "%04d.drawing", max(1, page))
    }

    /// 这一页有没有批注。
    static func hasDrawing(remoteID: Int, name: String, page: Int) -> Bool {
        guard let url = drawingURL(remoteID: remoteID, name: name, page: page) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// 这本书里哪些页有批注。用于页面列表上打标记。
    static func annotatedPages(remoteID: Int, name: String) -> Set<Int> {
        guard let directory = bookDirectory(remoteID: remoteID, name: name)?
            .appendingPathComponent(drawingsDirectoryName, isDirectory: true),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var result = Set<Int>()
        for name in names where name.hasSuffix(".drawing") {
            let digits = name.dropLast(".drawing".count)
            if let number = Int(digits) { result.insert(number) }
        }
        return result
    }

    /// 存一页批注。空批注（用户清空了）会把文件删掉，而不是留一个空文件 ——
    /// 否则"这页有批注"的标记会一直亮着。
    @discardableResult
    static func saveDrawing(_ data: Data?, remoteID: Int, name: String, page: Int) -> Bool {
        guard let url = drawingURL(remoteID: remoteID, name: name, page: page) else { return false }
        guard let data, !data.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        guard ensureDirectory(url.deletingLastPathComponent()) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 读一页批注。
    static func loadDrawing(remoteID: Int, name: String, page: Int) -> Data? {
        guard let url = drawingURL(remoteID: remoteID, name: name, page: page) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// 整本的批注删掉。
    @discardableResult
    static func removeAllDrawings(remoteID: Int, name: String) -> Bool {
        guard let directory = bookDirectory(remoteID: remoteID, name: name)?
            .appendingPathComponent(drawingsDirectoryName, isDirectory: true) else { return false }
        try? FileManager.default.removeItem(at: directory)
        return true
    }

    /// 整本的批注占了多少空间。
    static func drawingByteCount(remoteID: Int, name: String) -> Int64 {
        guard let directory = bookDirectory(remoteID: remoteID, name: name)?
            .appendingPathComponent(drawingsDirectoryName, isDirectory: true),
              let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
              ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize { total += Int64(size) }
        }
        return total
    }

    /// 书目录名：`42-色彩静物`
    static func bookFolderName(remoteID: Int, name: String) -> String {
        "\(remoteID)-\(safeComponent(name))"
    }

    /// 把任意字符串收敛成安全的单个路径分量。
    ///
    /// - Parameter maxUTF8Bytes: 上限，默认 180 —— 留出余量给 `<id>-` 前缀、
    ///   `/pages/0001.jpg` 后缀，以及文件系统的 255 字节上限。
    static func safeComponent(_ raw: String, maxUTF8Bytes: Int = 180) -> String {
        var text = raw

        // ① 去掉路径分隔符与 Windows/iOS 都不接受的字符
        let forbidden = Set<Character>("/\\:*?\"<>|")
        text = String(text.filter { !forbidden.contains($0) })

        // ② 去掉控制字符（含换行、制表）与零宽字符
        text = String(text.unicodeScalars.filter { scalar in
            !(scalar.value < 0x20) && !(0x7F...0x9F).contains(scalar.value)
                && scalar.value != 0x200B && scalar.value != 0xFEFF
        })

        // ③ 空白折叠
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")

        // ④ 去掉首尾的点与空格（末尾点在某些文件系统上会丢，首点像隐藏文件）
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ". "))

        // ⑤ 截断到字节上限，且不能把一个多字节字符切一半
        text = truncate(text, toUTF8Bytes: maxUTF8Bytes)

        // ⑥ 去掉截断后可能又露出来的尾部点/空格
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: ". "))

        // ⑦ 空的话给个兜底名 —— 原脚本这里会生成一个空目录名，直接失败
        return text.isEmpty ? "未命名教材" : text
    }

    /// 按 UTF-8 字节数截断，保证不切碎多字节字符。
    static func truncate(_ text: String, toUTF8Bytes limit: Int) -> String {
        guard limit > 0 else { return "" }
        if text.utf8.count <= limit { return text }

        var result = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > limit { break }
            result.append(character)
            used += size
        }
        return result
    }

    // MARK: 落盘

    /// 确保目录存在。
    @discardableResult
    static func ensureDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    /// 整本删掉本地文件。
    @discardableResult
    static func removeBookFiles(remoteID: Int, name: String) -> Bool {
        guard let directory = bookDirectory(remoteID: remoteID, name: name) else { return false }
        do {
            try FileManager.default.removeItem(at: directory)
            return true
        } catch {
            // 本来就不存在也算成功
            return !FileManager.default.fileExists(atPath: directory.path)
        }
    }

    /// 这本书在本地占了多少字节。
    static func localByteCount(remoteID: Int, name: String) -> Int64 {
        guard let directory = bookDirectory(remoteID: remoteID, name: name),
              let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
              ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true, let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// 一个稳定的文件名哈希，给封面缓存用（封面 URL 可能很长/重复）。
    static func cacheKey(for urlString: String) -> String {
        let digest = SHA256.hash(data: Data(urlString.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
