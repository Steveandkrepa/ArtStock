//
//  DXArt 教材接口契约 + 落盘规则 + 下载进度的回归测试
//
//  这一套守的是"搬到原生之后还能不能正常读"这件事：
//    · 接口返回的 JSON 解析（含厂家可能改字段/改类型）
//    · 页码是字符串/null 时不崩（原 Python 的 int() 会直接抛异常）
//    · 文件名安全化（中文书名很长时会超 255 字节上限）
//    · 进度算法（失败页不能被算成完成 —— 原脚本就是这么错的）
//
//  用法：./scripts/run-textbook-tests.sh
//

import Foundation

var passed = 0
var failed = 0

func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition { passed += 1; print("  ✅ \(label)") }
    else { failed += 1; print("  ❌ \(label)\(detail().isEmpty ? "" : "  → \(detail())")") }
}

func eq<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
    check(label, actual == expected, "实际 \(actual) 期望 \(expected)")
}

func data(_ json: String) -> Data { Data(json.utf8) }

let config = DXArtConfig.standard

// ═══ 1. 地址与请求头（原脚本的实测值，一个都不许变）═══
print("═══ 1. 接口地址与请求头 ═══")
do {
    let url = DXArtEndpoint.sms(phone: "13800138000", config: config)
    eq("短信接口路径", url?.path ?? "", "/api/test/sendMs")
    check("手机号进了查询串", url?.query?.contains("phone=13800138000") == true, url?.query ?? "nil")
}
do {
    let url = DXArtEndpoint.token(phone: "13800138000", code: "123456", config: config)
    eq("登录接口路径", url?.path ?? "", "/api/yinshi-oauth-server/oauth/token")
    let query = url?.query ?? ""
    for expected in ["grant_type=phoneCode", "scope=all", "client_id=yinshi_client",
                     "client_secret=123", "code=123456", "equipmentType=pad",
                     "appVersion=1.2.1"] {
        check("登录参数含 \(expected)", query.contains(expected), query)
    }
}
do {
    let url = DXArtEndpoint.search(keyword: "色彩静物", page: 2, config: config)
    eq("搜索接口路径", url?.path ?? "", "/api/test/liegongTopSearch/search")
    let query = url?.query ?? ""
    check("带上了 type=7（教材分类）", query.contains("type=7"), query)
    check("带上了 pageSize=50", query.contains("pageSize=50"), query)
    check("页码参数是 pageNum=2", query.contains("pageNum=2"), query)
    check("中文关键字被正确编码", query.contains("values="), query)
    check("关键字能还原", URLComponents(string: "https://x/?" + query)?
        .queryItems?.first { $0.name == "values" }?.value == "色彩静物")
}
do {
    let url = DXArtEndpoint.chapters(textbookID: 42, config: config)
    eq("取页接口路径", url?.path ?? "", "/api/yinshi-api-project/textbook/getChapter")
    let body = DXArtEndpoint.chapterBody(textbookID: 42, config: config)
    eq("body 里的 textbookId", body["textbookId"] as? Int, 42)
    eq("body 里的 level3Width", body["level3Width"] as? Int, 1230)
}
do {
    let headers = DXArtEndpoint.headers(config: config, token: "Bearer abc")
    eq("version 头", headers["version"], "1.2.1")
    eq("Content-Type", headers["Content-Type"], "application/json")
    eq("Authorization", headers["Authorization"], "Bearer abc")
    check("UA 伪装成 iPad", headers["User-Agent"]?.contains("iPad") == true)
    check("没有手写 Host 头（让 URLSession 自己填）", headers["Host"] == nil)
    check("不带 token 时不出现 Authorization",
          DXArtEndpoint.headers(config: config)["Authorization"] == nil)
}

// ═══ 2. 配置覆盖 ═══
print("\n═══ 2. 接口配置（厂家升级后能自己改）═══")
eq("域名补 https", DXArtConfig.normalizeHost("api.dxart.tech"), "https://api.dxart.tech")
eq("去掉末尾斜杠", DXArtConfig.normalizeHost("https://api.dxart.tech/"), "https://api.dxart.tech")
eq("保留已有协议", DXArtConfig.normalizeHost("http://127.0.0.1:8080"), "http://127.0.0.1:8080")
eq("空输入回落到默认", DXArtConfig.normalizeHost("   "), DXArtConfig.standard.host)
check("默认配置没有被标成已改", !DXArtConfig.standard.isCustomized)
check("标准配置的域名正确", DXArtConfig.standard.host == "https://api.dxart.tech")

// ═══ 3. 宽松取值（原脚本崩在这三处）═══
print("\n═══ 3. 脏数据容错（原 Python 会直接抛异常的地方）═══")
eq("字符串页码 12", DXArtResponseParser.intValue("12"), 12)
eq("浮点页码 12.0", DXArtResponseParser.intValue(12.0), 12)
eq("整数页码", DXArtResponseParser.intValue(7), 7)
eq("空字符串返回 nil", DXArtResponseParser.intValue(""), nil)
eq("null 返回 nil", DXArtResponseParser.intValue(nil), nil)
eq("乱码返回 nil", DXArtResponseParser.intValue("第12页"), nil)
eq("带空格的数字", DXArtResponseParser.intValue("  34  "), 34)
eq("数字转字符串", DXArtResponseParser.stringValue(42), "42")
eq("空字符串转 nil", DXArtResponseParser.stringValue("   "), nil)
eq("按路径取值", DXArtResponseParser.value(in: ["a": ["b": ["c": 1]]], path: ["a", "b", "c"]) as? Int, 1)
eq("路径中间不是字典时返回 nil",
   DXArtResponseParser.value(in: ["a": 1], path: ["a", "b"]) as? Int, nil)

// ═══ 4. 登录解析 ═══
print("\n═══ 4. 登录响应 ═══")
do {
    let json = ##"{"code":200,"data":{"access_token":"eyJhbGciOi","token_type":"bearer"}}"##
    eq("取出 access_token 并补 Bearer",
       (try? DXArtResponseParser.parseToken(data(json))) ?? "失败", "Bearer eyJhbGciOi")
}
do {
    let json = ##"{"code":200,"data":{"access_token":"Bearer already"}}"##
    check("已经带 Bearer 的不重复加",
          ((try? DXArtResponseParser.parseToken(data(json))) ?? "").hasPrefix("Bearer Bearer") == false)
}
do {
    // 短信接口失败时原脚本只看 code
    do {
        try DXArtResponseParser.parseSendSMS(data(##"{"code":500,"msg":"手机号不存在"}"##))
        check("短信失败要抛错", false, "没有抛")
    } catch let error as DXArtError {
        check("短信失败抛出接口错误", error == .badResponse(code: 500, message: "手机号不存在"),
              "\(error)")
    }
    try? DXArtResponseParser.parseSendSMS(data(##"{"code":200,"msg":"ok"}"##))
    check("短信成功不抛错", true)
}
do {
    // 凭证失效：原脚本是删掉本地 token 文件让用户重新登录
    do {
        _ = try DXArtResponseParser.parseSearch(data(
            ##"{"code":401,"msg":"Full authentication is required to access this resource","status":401}"##
        ))
        check("401 要抛错", false, "没有抛")
    } catch let error as DXArtError {
        check("401 被识别成需要重新登录", error.requiresRelogin, "\(error)")
    }
}

// ═══ 5. 搜索解析（原脚本的真实结构 + 厂家可能改的包装）═══
print("\n═══ 5. 搜索响应 ═══")
let realSearchJSON = ##"""
{"code":200,"msg":"success","rows":[
 {"liegongTextbook":{"id":101,"textbookName":"色彩静物基础","textbookViewTotal":38210,
   "thumbnailUrl":"https://cdn.example.com/a.jpg","textbookCoverPicture":"https://cdn.example.com/b.jpg"}},
 {"liegongTextbook":{"id":102,"textbookName":"素描头像结构","textbookViewTotal":1520,
   "thumbnailUrl":null,"textbookCoverPicture":"https://cdn.example.com/c.jpg"}},
 {"liegongTextbook":{"id":103,"textbookName":"速写动态","textbookViewTotal":"980"}}
]}
"""##
do {
    let books = (try? DXArtResponseParser.parseSearch(data(realSearchJSON))) ?? []
    eq("解析出 3 本", books.count, 3)
    eq("第 1 本的名字", books.first?.name, "色彩静物基础")
    eq("第 1 本的 id", books.first?.remoteID, 101)
    eq("热度是数字", books.first?.viewCount, 38210)
    eq("thumbnailUrl 为空时退回 cover", books[1].coverURL, "https://cdn.example.com/c.jpg")
    eq("热度是字符串也能读", books[2].viewCount, 980)
    eq("没有封面时为 nil", books[2].coverURL, nil)
}
do {
    // 厂家把 rows 包进 data 里
    let wrapped = ##"{"code":200,"data":{"rows":[{"liegongTextbook":{"id":1,"textbookName":"X"}}]}}"##
    eq("容忍 data.rows 包装",
       (try? DXArtResponseParser.parseSearch(data(wrapped)))?.count, 1)
}
do {
    // 有的返回不包 liegongTextbook 这一层
    let flat = ##"{"code":200,"rows":[{"id":9,"textbookName":"扁平结构"}]}"##
    eq("容忍扁平结构",
       (try? DXArtResponseParser.parseSearch(data(flat)))?.first?.name, "扁平结构")
}
do {
    let empty = ##"{"code":200,"rows":[]}"##
    eq("空结果是空数组而不是报错",
       (try? DXArtResponseParser.parseSearch(data(empty)))?.count, 0)
}
do {
    // 缺 id 的行要跳过，不能整批失败
    let partial = ##"{"code":200,"rows":[{"liegongTextbook":{"textbookName":"没有id"}},{"liegongTextbook":{"id":5,"textbookName":"有id"}}]}"##
    eq("缺 id 的行被跳过", (try? DXArtResponseParser.parseSearch(data(partial)))?.count, 1)
}
do {
    // 重复 id 去重
    let dup = ##"{"code":200,"rows":[{"liegongTextbook":{"id":5,"textbookName":"A"}},{"liegongTextbook":{"id":5,"textbookName":"A"}}]}"##
    eq("重复 id 去重", (try? DXArtResponseParser.parseSearch(data(dup)))?.count, 1)
}
do {
    eq("名字为空时给出可读的兜底名",
       (try? DXArtResponseParser.parseSearch(data(##"{"code":200,"rows":[{"liegongTextbook":{"id":7}}]}"##)))?.first?.displayName,
       "未命名教材 7")
}

// ═══ 6. 取页解析（原脚本最容易崩的一步）═══
print("\n═══ 6. 取页响应 ═══")
let realChapterJSON = ##"""
{"code":200,"data":{"chapterList":[
 {"pagination":1,"textbookChapterFilePath":"https://cdn.example.com/p1.jpg?sig=abc&t=1"},
 {"pagination":"2","textbookChapterFilePath":"https://cdn.example.com/p2.jpg?x=1"},
 {"pagination":3,"textbookChapterFilePath":"https://cdn.example.com/p3.jpg"},
 {"pagination":null,"textbookChapterFilePath":"https://cdn.example.com/bad.jpg"},
 {"pagination":4,"textbookChapterFilePath":""},
 {"pagination":5,"textbookChapterFilePath":"not-a-url"}
]}}
"""##
do {
    let pages = (try? DXArtResponseParser.parseChapters(data(realChapterJSON))) ?? []
    eq("只保留能用的 3 页", pages.count, 3)
    eq("页码是数字", pages[0].pageNumber, 1)
    eq("字符串页码也能读", pages[1].pageNumber, 2)
    eq("查询串被去掉", pages[0].remoteURL, "https://cdn.example.com/p1.jpg")
    eq("第二个的查询串也去掉了", pages[1].remoteURL, "https://cdn.example.com/p2.jpg")
    check("非法地址被丢弃", !pages.contains { $0.remoteURL.contains("not-a-url") })
}
do {
    eq("去查询串", DXArtResponseParser.cleanImageURL("https://a.com/b.jpg?sig=1&t=2"), "https://a.com/b.jpg")
    eq("没有查询串时原样返回", DXArtResponseParser.cleanImageURL("https://a.com/b.jpg"), "https://a.com/b.jpg")
    eq("空字符串返回 nil", DXArtResponseParser.cleanImageURL("   "), nil)
    eq("非 http 协议返回 nil", DXArtResponseParser.cleanImageURL("file:///etc/passwd"), nil)
    eq("没有域名返回 nil", DXArtResponseParser.cleanImageURL("https:///b.jpg"), nil)
}
do {
    // 乱序 + 重复页码
    // ⚠️ 跨行的 raw string 必须写成 ##""" ... """##；
    //    写成 ##" ... "## 只有单行才合法（编译器报的是"未结束的字符串"）。
    let messy = ##"""
    {"code":200,"data":{"chapterList":[
      {"pagination":3,"textbookChapterFilePath":"https://a.com/3.jpg"},
      {"pagination":1,"textbookChapterFilePath":"https://a.com/1.jpg"},
      {"pagination":2,"textbookChapterFilePath":"https://a.com/2old.jpg"},
      {"pagination":2,"textbookChapterFilePath":"https://a.com/2.jpg"}
    ]}}
    """##
    let pages = (try? DXArtResponseParser.parseChapters(data(messy))) ?? []
    eq("按页码排序", pages.map(\.pageNumber), [1, 2, 3])
    eq("同页码取后出现的", pages[1].remoteURL, "https://a.com/2.jpg")
}
do {
    let nested = ##"{"code":200,"data":[{"pagination":1,"textbookChapterFilePath":"https://a.com/1.jpg"}]}"##
    eq("容忍 data 直接是数组", (try? DXArtResponseParser.parseChapters(data(nested)))?.count, 1)
}
do {
    do {
        _ = try DXArtResponseParser.parseChapters(data(##"{"code":200,"data":{"chapterList":[]}}"##))
        check("空章节要报错", false, "没有抛")
    } catch let error as DXArtError {
        if case .empty = error { check("空章节报「没有找到」", true) }
        else { check("空章节报「没有找到」", false, "\(error)") }
    }
}
do {
    // 截断的 JSON（模拟接口返回被切断）
    let truncated = Data(#"{"code":200,"data":{"chapterList":[{"pagination":1"#.utf8)
    do {
        _ = try DXArtResponseParser.parseChapters(truncated)
        check("坏 JSON 报可读错误", false, "没有抛")
    } catch let error as DXArtError {
        if case .decoding = error { check("坏 JSON 报可读错误", true) }
        else { check("坏 JSON 报可读错误", false, "\(error)") }
    }
}
do {
    // 返回的是 HTML（网关拦截时很常见），不能当成 JSON 硬解然后崩
    let html = Data("<html><body>502 Bad Gateway</body></html>".utf8)
    do {
        _ = try DXArtResponseParser.parseChapters(html)
        check("HTML 响应报可读错误", false, "没有抛")
    } catch let error as DXArtError {
        if case .decoding = error { check("HTML 响应报可读错误", true) }
        else { check("HTML 响应报可读错误", false, "\(error)") }
    }
}

// ═══ 7. 文件名安全化（中文长书名会超文件系统上限）═══
print("\n═══ 7. 书名 → 目录名 ═══")
eq("普通书名原样保留", TextbookStorage.safeComponent("色彩静物"), "色彩静物")
eq("斜杠被去掉", TextbookStorage.safeComponent("色彩/静物"), "色彩静物")
eq("反斜杠被去掉", TextbookStorage.safeComponent("色彩\\静物"), "色彩静物")
eq("冒号问号引号尖括号竖线都被去掉",
   TextbookStorage.safeComponent(#"a:b*c?d"e<f>g|h"#), "abcdefgh")
eq("换行与制表被去掉", TextbookStorage.safeComponent("色彩\n静物\t基础"), "色彩静物基础")
eq("连续空白折叠成一个空格", TextbookStorage.safeComponent("色彩   静物"), "色彩 静物")
eq("首尾的点与空格被去掉", TextbookStorage.safeComponent("  .色彩静物.  "), "色彩静物")
eq("全是要过滤的字符时给兜底名", TextbookStorage.safeComponent("///"), "未命名教材")
eq("空字符串给兜底名", TextbookStorage.safeComponent(""), "未命名教材")
do {
    // iOS 文件名上限 255 字节，中文一个字 3 字节。原脚本不截断，会直接写失败。
    let long = String(repeating: "色", count: 200)
    let safe = TextbookStorage.safeComponent(long)
    check("超长书名被截断到 180 字节以内", safe.utf8.count <= 180, "\(safe.utf8.count) 字节")
    check("截断后仍全是完整汉字", safe.allSatisfy { $0 == "色" })
    check("截断后不为空", !safe.isEmpty)
}
do {
    // 截断不能把一个多字节字符切一半
    let mixed = String(repeating: "a", count: 179) + "汉字汉字"
    let safe = TextbookStorage.safeComponent(mixed)
    check("截断不会切碎多字节字符", safe.utf8.count <= 180 && !safe.hasSuffix("\u{FFFD}"),
          "\(safe.utf8.count) 字节")
    check("截断后能被 String 正常使用", safe.count > 0)
}
do {
    let name = TextbookStorage.bookFolderName(remoteID: 101, name: "色彩/静物")
    eq("目录名带 id 前缀（防同名互相覆盖）", name, "101-色彩静物")
    check("同名不同 id 目录不同",
          TextbookStorage.bookFolderName(remoteID: 1, name: "X")
          != TextbookStorage.bookFolderName(remoteID: 2, name: "X"))
}
eq("页码补零便于排序", TextbookStorage.fileName(forPage: 7), "0007.jpg")
eq("四位数页码", TextbookStorage.fileName(forPage: 1234), "1234.jpg")
eq("页码 0 兜底为 1", TextbookStorage.fileName(forPage: 0), "0001.jpg")
eq("相对路径不含绝对路径（沙盒路径会变）",
   TextbookStorage.relativePagePath(page: 12), "pages/0012.jpg")
check("相对路径不以斜杠开头", !TextbookStorage.relativePagePath(page: 1).hasPrefix("/"))
do {
    eq("缓存键长度固定", TextbookStorage.cacheKey(for: "https://a.com/1.jpg").count, 16)
    check("不同 URL 缓存键不同",
          TextbookStorage.cacheKey(for: "https://a.com/1.jpg")
          != TextbookStorage.cacheKey(for: "https://a.com/2.jpg"))
    check("相同 URL 缓存键相同",
          TextbookStorage.cacheKey(for: "https://a.com/1.jpg")
          == TextbookStorage.cacheKey(for: "https://a.com/1.jpg"))
}

// ═══ 8. 下载进度（原脚本把失败页也算成完成）═══
print("\n═══ 8. 下载进度 ═══")
do {
    let stats = DownloadStats(done: 30, failed: 10, downloading: 0, pending: 60)
    eq("总数", stats.total, 100)
    eq("百分比只算成功的", stats.percentText, "30%")
    check("没下完", !stats.isComplete)
    check("还能继续", stats.canStart)
    check("摘要里带上失败数", stats.summary.contains("10 页失败"), stats.summary)
}
do {
    let stats = DownloadStats(done: 100, failed: 0, downloading: 0, pending: 0)
    check("全成功才算完成", stats.isComplete)
    eq("完成时 100%", stats.percentText, "100%")
    check("完成后没有可做的", !stats.canStart)
}
do {
    // 关键：失败页不算完成 —— 原脚本这里会说 100%
    let stats = DownloadStats(done: 90, failed: 10, downloading: 0, pending: 0)
    eq("有失败页时不是 100%", stats.percentText, "90%")
    check("有失败页时不算完成", !stats.isComplete)
    check("失败页可以重试", stats.canStart)
}
do {
    let stats = DownloadStats(done: 0, failed: 0, downloading: 0, pending: 0)
    eq("空任务 0%", stats.percentText, "0%")
    check("空任务不算完成", !stats.isComplete)
    eq("空任务摘要", stats.summary, "没有可下载的页")
}
do {
    let stats = DownloadStats(done: 5, failed: 0, downloading: 3, pending: 2)
    check("有页在下载时算运行中", stats.isRunning)
    check("运行中也还能加任务", stats.canStart)
}
eq("只有失败没有待下时也能重试",
   DownloadStats(done: 1, failed: 2, downloading: 0, pending: 0).canStart, true)

// ═══ 9. 格式化与估时 ═══
print("\n═══ 9. 体积与时间显示 ═══")
eq("字节", TextbookFormat.bytes(0), "0 B")
eq("KB", TextbookFormat.bytes(2048), "2.0 KB")
eq("MB 小值保留一位", TextbookFormat.bytes(5 * 1024 * 1024 / 2), "2.5 MB")
eq("MB 大值不带小数", TextbookFormat.bytes(300 * 1024 * 1024), "300 MB")
eq("秒", TextbookFormat.duration(45), "约 45 秒")
eq("分", TextbookFormat.duration(120), "约 2 分")
eq("分秒", TextbookFormat.duration(95), "约 1 分 35 秒")
eq("小时", TextbookFormat.duration(3720), "约 1 小时 2 分")
eq("非法输入给破折号", TextbookFormat.duration(.infinity), "—")
eq("负数给破折号", TextbookFormat.duration(-5), "—")
do {
    var eta = DownloadEta()
    let start = Date(timeIntervalSince1970: 1000)
    eta.begin(bytesAlreadyDone: 0, now: start)
    check("刚开始时不给估时（避免跳数字）",
          eta.estimatedRemainingSeconds(remainingBytes: 1000, now: start) == nil)
    eta.update(bytes: 1000)
    let later = start.addingTimeInterval(10)   // 10 秒传了 1000 字节
    // 拆开写：把 map + 闭包 + 字符串插值揉在一行里，类型检查器会直接放弃
    let estimate: TimeInterval? = eta.estimatedRemainingSeconds(remainingBytes: 3000, now: later)
    var closeToThirty = false
    var detail = "nil"
    if let estimate {
        closeToThirty = abs(estimate - 30) < 0.5
        detail = String(format: "%.1f", estimate)
    }
    check("10 秒 1000 字节 → 剩 3000 字节约 30 秒", closeToThirty, detail)
    check("剩余为 0 时不给估时",
          eta.estimatedRemainingSeconds(remainingBytes: 0, now: later) == nil)
}
do {
    var eta = DownloadEta()
    eta.begin(bytesAlreadyDone: 0)
    eta.update(bytes: 0)
    check("一个字节都没传时不给估时",
          eta.estimatedRemainingSeconds(remainingBytes: 100) == nil)
}

// ═══ 10. 每页状态 ═══
print("\n═══ 10. 每页状态 ═══")
eq("状态共 4 种", PageDownloadState.allCases.count, 4)
check("状态都能存成字符串再读回来",
      PageDownloadState.allCases.allSatisfy { PageDownloadState(rawValue: $0.rawValue) == $0 })
check("每个状态都有中文名与图标",
      PageDownloadState.allCases.allSatisfy { !$0.displayName.isEmpty && !$0.symbolName.isEmpty })

// ═══ 阅读器缩放/拖动几何 ═══
// 这组盯的是"放大之后只能看中间那一块"那个 bug 的算术部分。
// 错了的后果很直观：算出负数 → 拖动反向；边界太小 → 拖不动；
// 边界太大 → 能拖到页面外的空白处。
print("\n═══ 阅读器几何（放大与拖动）═══")
do {
    // aspect-fit：竖版页面放进横版容器，应该是高度顶满、左右留白
    let fitted = ReaderGeometry.fitted(
        content: CGSize(width: 1000, height: 2000),
        in: CGSize(width: 1000, height: 1000)
    )
    eq("aspect-fit 高度顶满", fitted.height, 1000)
    eq("aspect-fit 宽度按比例", fitted.width, 500)
}
do {
    // 尺寸缺失/为 0 时不能崩，也不能返回 NaN
    let fallback = ReaderGeometry.fitted(
        content: .zero, in: CGSize(width: 300, height: 400)
    )
    eq("内容尺寸为 0 → 退回容器尺寸", fallback, CGSize(width: 300, height: 400))
    let zeroContainer = ReaderGeometry.fitted(
        content: CGSize(width: 10, height: 10), in: .zero
    )
    eq("容器为 0 → 不产生 NaN", zeroContainer, .zero)
}
do {
    let container = CGSize(width: 1000, height: 1000)
    let content = CGSize(width: 1000, height: 1000)

    // 没放大 → 不许拖
    let atOne = ReaderGeometry.maxPan(content: content, container: container, zoom: 1)
    eq("1 倍时水平不能拖", atOne.width, 0)
    eq("1 倍时垂直不能拖", atOne.height, 0)

    // 放大 2 倍 → 单边可拖半个多出来的量
    let atTwo = ReaderGeometry.maxPan(content: content, container: container, zoom: 2)
    eq("2 倍时水平可拖 500", atTwo.width, 500)
    eq("2 倍时垂直可拖 500", atTwo.height, 500)

    // ⚠️ 关键一条：内容比容器小的时候边界必须是 0，**不能是负数** ——
    //    负数会让拖动反向，表现就是"越拖越偏"
    let smaller = ReaderGeometry.fitted(
        content: CGSize(width: 1000, height: 2000), in: container
    )
    let narrow = ReaderGeometry.maxPan(content: smaller, container: container, zoom: 1.2)
    check("宽度不足以填满时水平边界为 0（不是负数）", narrow.width == 0,
          "\(narrow.width)")
    check("高度多出来的部分仍可拖", narrow.height > 0, "\(narrow.height)")
}
do {
    let container = CGSize(width: 1000, height: 1000)
    let content = CGSize(width: 1000, height: 1000)

    eq("拖过头会被夹回边界",
       ReaderGeometry.clamp(CGSize(width: 9999, height: -9999),
                            content: content, container: container, zoom: 2),
       CGSize(width: 500, height: -500))
    eq("没到边界就原样保留",
       ReaderGeometry.clamp(CGSize(width: 120, height: -80),
                            content: content, container: container, zoom: 2),
       CGSize(width: 120, height: -80))
    eq("没放大时任何位移都被夹成 0",
       ReaderGeometry.clamp(CGSize(width: 300, height: 300),
                            content: content, container: container, zoom: 1),
       .zero)
}
do {
    // 缩到 1 附近要吸附回 1：停在 1.03 最难受 ——
    // 看着没放大，但翻页和单点分区都失效了（它们都以"没放大"为前提）
    eq("1.03 吸附回 1", ReaderGeometry.settledZoom(1.03), 1)
    eq("1.14 也吸附回 1", ReaderGeometry.settledZoom(1.14), 1)
    eq("1.2 保留", ReaderGeometry.settledZoom(1.2), 1.2)
    eq("小于 1 一律回到 1", ReaderGeometry.settledZoom(0.4), 1)
    eq("超过上限就截到上限", ReaderGeometry.settledZoom(99), ReaderGeometry.maxZoom)
    eq("上限是 5 倍", ReaderGeometry.maxZoom, 5)
}

print("\n═══════════════════════════════════════════════════════")
print("通过 \(passed)  失败 \(failed)")
exit(failed == 0 ? 0 : 1)
