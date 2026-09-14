// Swift 实现及修改：Yuedu 项目，2026-09-14。
// 来源与许可见仓库根目录 THIRD_PARTY_NOTICES.md（GPL-3.0）。
import Foundation

/// URL 规则中 `,{...}` 之后的选项。
struct UrlOption: Decodable {
    var method: String?
    var charset: String?
    var headers: FlexibleHeaders?
    var body: FlexibleBody?
    var type: String?
    var js: String?
    var webJs: String?
    var webView: FlexibleBool?
    var retry: FlexibleInt?
    var serverID: FlexibleInt?

    enum CodingKeys: String, CodingKey {
        case method, charset, headers, body, type, js, webJs, webView, retry
        case serverID = "serverID"
    }

    /// headers 可能是对象或 JSON 字符串
    struct FlexibleHeaders: Decodable {
        var map: [String: String] = [:]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let dict = try? container.decode([String: String].self) {
                map = dict
                return
            }
            // 值可能是数字 / 布尔，统一转字符串
            if let any = try? container.decode([String: AnyCodableValue].self) {
                map = any.mapValues { $0.stringValue }
                return
            }
            if let raw = try? container.decode(String.self),
               let data = raw.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                map = dict.mapValues { String(describing: $0) }
                return
            }
            map = [:]
        }
    }

    /// body 可能是字符串，也可能是 JSON 对象（此时需原样序列化回字符串）
    struct FlexibleBody: Decodable {
        var text: String = ""

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let raw = try? container.decode(String.self) {
                text = raw
                return
            }
            if let any = try? container.decode(AnyCodableValue.self) {
                text = any.jsonString
                return
            }
            text = ""
        }
    }
}

/// 通用 JSON 值包装，用于宽松解码书源里格式不统一的字段
enum AnyCodableValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: AnyCodableValue])
    case array([AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: AnyCodableValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([AnyCodableValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    var stringValue: String {
        switch self {
        case let .string(v): return v
        case let .int(v): return String(v)
        case let .double(v):
            return v.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(v)) : String(v)
        case let .bool(v): return v ? "true" : "false"
        case .object, .array: return jsonString
        case .null: return ""
        }
    }

    var jsonString: String {
        guard let data = try? JSONSerialization.data(withJSONObject: anyValue) else {
            return stringValue
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    var anyValue: Any {
        switch self {
        case let .string(v): return v
        case let .int(v): return v
        case let .double(v): return v
        case let .bool(v): return v
        case let .object(v): return v.mapValues { $0.anyValue }
        case let .array(v): return v.map { $0.anyValue }
        case .null: return NSNull()
        }
    }
}

/// 搜索 / 发现 / 目录 / 正文的 URL 规则解析。
///
/// URL 处理顺序：
/// 1. `analyzeJs()`  —— 执行 `@js:` 与 `<js>...</js>`
/// 2. `replaceKeyPageJs()` —— 先替换内嵌 `{{js}}`，再替换 `<page1,page2>` 分页
/// 3. `analyzeUrl()` —— 切分 `,{...}` 选项、绝对化 URL、解析 query / body
///
/// 顺序不可调换：内嵌规则必须先于分页替换，否则规则中含 `<`、`>` 时会被切错。
///
/// 并发说明：实例状态在 `init` 中一次性算完，之后对外只读（`getStrResponse` 不改状态），
/// 因此可安全跨任务传递；标注 `@unchecked Sendable` 而非引入锁，避免热路径加锁开销。
public final class AnalyzeUrl: @unchecked Sendable {

    public private(set) var ruleUrl: String = ""
    public private(set) var url: String = ""
    public private(set) var body: String?
    public private(set) var type: String?
    public private(set) var method: String = "GET"
    public private(set) var headerMap: [String: String] = [:]
    public private(set) var charset: String?
    public private(set) var useWebView = false
    private var retry: Int = 0

    public private(set) var baseUrl: String = ""

    private let mUrl: String
    private let key: String?
    private let page: Int?
    private let source: BookSource?
    private let ruleData: RuleDataInterface?
    private let chapter: BookChapter?

    /// `,{` 之前为 URL 主体
    private static let paramPattern = TextFormatter.paramPattern
    /// `<page1,page2,...>` 分页规则
    private static let pagePattern: NSRegularExpression = {
        guard let regex = try? NSRegularExpression(pattern: "<(.*?)>") else {
            preconditionFailure("bad pagePattern")
        }
        return regex
    }()
    /// `@js:...` 或 `<js>...</js>`。
    static let jsPattern: NSRegularExpression = {
        guard let regex = try? NSRegularExpression(
            pattern: "\\{\\{(.*?)\\}\\}|@js:(.*?)$|<js>(.*?)</js>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else {
            preconditionFailure("bad jsPattern")
        }
        return regex
    }()
    /// 仅匹配 `@js:` / `<js>`（不含 `{{}}`），用于 URL 与规则的首段 JS 处理
    static let jsOnlyPattern: NSRegularExpression = {
        guard let regex = try? NSRegularExpression(
            pattern: "@js:(.*?)$|<js>(.*?)</js>",
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else {
            preconditionFailure("bad jsOnlyPattern")
        }
        return regex
    }()

    public init(
        mUrl: String,
        key: String? = nil,
        page: Int? = nil,
        baseUrl: String = "",
        source: BookSource? = nil,
        ruleData: RuleDataInterface? = nil,
        chapter: BookChapter? = nil,
        headerMapF: [String: String]? = nil
    ) throws {
        self.mUrl = mUrl
        self.key = key
        self.page = page
        self.source = source
        self.ruleData = ruleData
        self.chapter = chapter

        // baseUrl 自身可能带 `,{...}`，需先截断
        var base = baseUrl
        let ns = base as NSString
        if let match = Self.paramPattern.firstMatch(
            in: base, range: NSRange(location: 0, length: ns.length)
        ) {
            base = ns.substring(to: match.range.location)
        }
        self.baseUrl = base

        if let headerMapF {
            headerMap = headerMapF
        } else if let source {
            headerMap = source.headerMap()
        } else {
            headerMap = ["User-Agent": AppConstants.defaultUserAgent]
        }
        // proxy 不是真实请求头，取出后移除
        headerMap.removeValue(forKey: "proxy")

        initUrl()
    }

    // MARK: - 处理链

    private func initUrl() {
        ruleUrl = mUrl
        analyzeJs()
        replaceKeyPageJs()
        analyzeUrl()
    }

    /// 执行 `@js:` / `<js></js>`。
    private func analyzeJs() {
        var start = 0
        var result = ruleUrl
        let ns = ruleUrl as NSString
        let matches = Self.jsOnlyPattern.matches(
            in: ruleUrl, range: NSRange(location: 0, length: ns.length)
        )
        for match in matches {
            if match.range.location > start {
                let segment = ns
                    .substring(with: NSRange(location: start, length: match.range.location - start))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !segment.isEmpty {
                    // 前置片段中的 @result 用上一步结果替换
                    result = segment.replacingOccurrences(of: "@result", with: result)
                }
            }
            let script = captured(match, in: ns, groups: [1, 2]) ?? ""
            if !script.isEmpty {
                let evaluated = evalJS(script, result: result)
                result = Self.stringify(evaluated) ?? result
            }
            start = match.range.location + match.range.length
        }
        if ns.length > start {
            let segment = ns.substring(from: start)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !segment.isEmpty {
                result = segment.replacingOccurrences(of: "@result", with: result)
            }
        }
        ruleUrl = result
    }

    /// 替换内嵌 `{{js}}` 与分页 `<a,b,c>`。
    private func replaceKeyPageJs() {
        // 1) 内嵌 {{js}}
        if ruleUrl.contains("{{") && ruleUrl.contains("}}") {
            let analyzer = RuleAnalyzer(ruleUrl)
            let replaced = analyzer.innerRule("{{", "}}") { [weak self] script in
                guard let self else { return "" }
                let value = self.evalJS(script, result: nil)
                return Self.stringify(value) ?? ""
            }
            if !replaced.isEmpty { ruleUrl = replaced }
        }

        // 2) 分页 <page1,page2>
        if let page {
            var current = ruleUrl
            while true {
                let ns = current as NSString
                guard let match = Self.pagePattern.firstMatch(
                    in: current, range: NSRange(location: 0, length: ns.length)
                ), match.numberOfRanges > 1 else { break }

                let pages = ns.substring(with: match.range(at: 1))
                    .split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                // page 从 1 开始；超出范围用最后一项
                let replacement = (page <= pages.count && page >= 1)
                    ? pages[page - 1]
                    : (pages.last ?? "")
                current = ns.replacingCharacters(in: match.range, with: replacement)
            }
            ruleUrl = current
        }
    }

    /// 解析 URL 主体与 `,{...}` 选项。
    private func analyzeUrl() {
        let ns = ruleUrl as NSString
        let optionMatch = Self.paramPattern.firstMatch(
            in: ruleUrl, range: NSRange(location: 0, length: ns.length)
        )
        let urlNoOption = optionMatch.map { ns.substring(to: $0.range.location) } ?? ruleUrl

        url = NetworkUtils.absoluteURL(base: baseUrl, relative: urlNoOption)
        if let base = NetworkUtils.baseURL(of: url) {
            baseUrl = base
        }

        guard let optionMatch else { return }

        let optionText = ns.substring(from: optionMatch.range.location + optionMatch.range.length)

        // 书源选项常用单引号 JSON（如 {'method':'POST'}），严格解析失败后转双引号重试
        var option: UrlOption?
        if let data = optionText.data(using: .utf8) {
            option = try? JSONDecoder().decode(UrlOption.self, from: data)
        }
        if option == nil,
           let relaxed = Self.singleToDoubleQuotes(optionText)?.data(using: .utf8) {
            option = try? JSONDecoder().decode(UrlOption.self, from: relaxed)
        }
        guard let option else {
            // 选项不是合法 JSON 时忽略，保证主体 URL 仍可用
            JSLog.shared.append("URL 选项解析失败：\(optionText)")
            return
        }

        if let m = option.method, m.uppercased() == "POST" {
            method = "POST"
        }
        for (key, value) in option.headers?.map ?? [:] {
            headerMap[key] = value
        }
        if let bodyText = option.body?.text, !bodyText.isEmpty {
            body = bodyText
        }
        type = option.type
        charset = option.charset
        retry = option.retry?.wrappedValue ?? 0
        useWebView = option.webView?.wrappedValue ?? false

        // option.js 可改写最终 url
        if let js = option.js, !js.isEmpty {
            if let evaluated = Self.stringify(evalJS(js, result: url)), !evaluated.isEmpty {
                url = evaluated
            }
        }
    }

    // MARK: - JS

    private func evalJS(_ script: String, result: Any?) -> Any? {
        var bindings: [String: Any] = [:]
        bindings["baseUrl"] = baseUrl
        if let key { bindings["key"] = key }
        if let page { bindings["page"] = page }
        if let result { bindings["result"] = result }
        // ruleData 是协议类型，书信息由 BookRuleData 包装持有。
        // 早前误写成 `ruleData as? Book`（Book 是 struct，转换恒为 nil），
        // 导致书源 JS 里的 bookName 永远取不到值。
        if let bookData = ruleData as? BookRuleData {
            bindings["bookName"] = bookData.book.name
            bindings["title"] = bookData.book.name
            bindings["author"] = bookData.book.author
        }

        return JSEngine.shared.evaluate(
            script,
            result: result,
            source: source,
            baseUrl: baseUrl,
            variableStore: ruleData?.variableStore,
            extraBindings: bindings
        )
    }

    /// JS 结果转字符串。整数型 Double 去掉小数点。
    static func stringify(_ value: Any?) -> String? {
        guard let value else { return nil }
        switch value {
        case let text as String: return text
        case let number as Int: return String(number)
        case let number as Double:
            return number.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", number) : String(number)
        case let flag as Bool: return flag ? "true" : "false"
        default: return String(describing: value)
        }
    }

    /// 单引号 JSON 转双引号（双引号内的单引号原样保留）。
    /// 转换后若引号未闭合则返回 nil，避免产出更糟的字符串。
    static func singleToDoubleQuotes(_ text: String) -> String? {
        var result = ""
        var inSingle = false
        var inDouble = false

        for ch in text {
            if ch == "\"" && !inSingle {
                inDouble.toggle()
                result.append(ch)
            } else if ch == "'" && !inDouble {
                inSingle.toggle()
                result.append("\"")
            } else {
                result.append(ch)
            }
        }
        return (inSingle || inDouble) ? nil : result
    }

    private func captured(
        _ match: NSTextCheckingResult, in ns: NSString, groups: [Int]
    ) -> String? {
        for group in groups where group < match.numberOfRanges {
            let range = match.range(at: group)
            if range.location != NSNotFound {
                return ns.substring(with: range)
            }
        }
        return nil
    }

    // MARK: - 请求

    /// 发起请求并返回响应
    public func getStrResponse() async throws -> StrResponse {
        if useWebView {
            // WebView 抓取未实现，降级为普通请求
            JSLog.shared.append("书源要求 WebView 抓取，iOS 端降级为普通请求：\(url)")
        }
        return try await HTTPClient.shared.request(
            url: url,
            method: method,
            body: body,
            headers: headerMap,
            charset: charset,
            retry: retry,
            source: source
        )
    }

    /// 获取正文字符串，空内容抛错以便上层切换书源
    public func getStrResponseBody() async throws -> String {
        let response = try await getStrResponse()
        guard let body = response.body, !body.isEmpty else {
            throw HTTPError.emptyBody(url)
        }
        return body
    }
}
