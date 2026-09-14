// Swift 实现及修改：Yuedu 项目，2026-09-14。
// 来源与许可见仓库根目录 THIRD_PARTY_NOTICES.md（GPL-3.0）。
import Foundation
import SwiftSoup

/// 规则数据载体协议。
/// 书源规则里的 `@put:{}` / `@get:{}` 通过它读写变量。
///
/// 标注 Sendable：内部可变状态全部收敛在线程安全的 `VariableStore`（NSLock 保护），
/// 且实例在一次解析流程中由单个任务顺序持有，不会并发写入。
public protocol RuleDataInterface: AnyObject, Sendable {
    var variableStore: VariableStore { get }
    func putVariable(_ key: String, _ value: String)
    func getVariable(_ key: String) -> String
}

/// 通用规则数据。
public final class RuleData: RuleDataInterface, @unchecked Sendable {
    public let variableStore: VariableStore

    public init(variable: String? = nil) {
        var initial: [String: String] = [:]
        // variable 以 JSON 字符串持久化
        if let variable, let data = variable.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            initial = dict
        }
        self.variableStore = VariableStore(initial: initial)
    }

    public func putVariable(_ key: String, _ value: String) {
        variableStore.put(key, value)
    }

    public func getVariable(_ key: String) -> String {
        variableStore.get(key)
    }

    /// 序列化以便随书籍一起保存
    public var variableJSON: String? {
        let all = variableStore.all
        guard !all.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: all) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// 书籍规则数据：附带 bookName 等内置变量。
/// `book` 仅在构造时写入、解析期间只读，故可安全跨线程传递。
public final class BookRuleData: RuleDataInterface, @unchecked Sendable {
    public let variableStore: VariableStore
    public var book: Book

    public init(book: Book) {
        self.book = book
        var initial: [String: String] = [:]
        if let variable = book.variable, let data = variable.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            initial = dict
        }
        self.variableStore = VariableStore(initial: initial)
    }

    public func putVariable(_ key: String, _ value: String) {
        variableStore.put(key, value)
    }

    public func getVariable(_ key: String) -> String {
        // bookName 为内置变量，优先返回
        if key == "bookName" { return book.name }
        return variableStore.get(key)
    }

    public var variableJSON: String? {
        let all = variableStore.all
        guard !all.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: all) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// 规则解析调度器。
///
/// 职责：把一条书源规则字符串拆成若干 `SourceRule`，按 mode 分派给
/// JSoup / XPath / JSONPath / Regex / JS 五种解析器，并处理：
/// - `@put:{}` / `@get:{}` 变量
/// - `{{js}}` 内嵌脚本
/// - `##正则##替换##` 后处理（第三个 `##` 表示只替换第一个匹配）
/// - `$1`..`$99` 正则分组回填
///
/// 解析器按内容标识缓存，实例需在所属规则执行队列中使用。
public final class AnalyzeRule {

    public enum Mode {
        case xPath, json, `default`, js, regex
    }

    // MARK: - 状态

    public var ruleData: RuleDataInterface?
    public var chapter: BookChapter?
    public var nextChapterUrl: String?

    private let source: BookSource?
    private var content: Any?
    private var baseUrl: String?
    private var redirectUrl: String?
    private var isJSON = false
    private var isRegex = false

    // 解析器缓存：content 未变时复用，避免同一页反复建 DOM
    private var cachedJSoup: AnalyzeByJSoup?
    private var cachedXPath: AnalyzeByXPath?
    private var cachedJSONPath: AnalyzeByJSonPath?
    private var cacheToken: Int = 0

    /// getString 规则缓存。
    private var stringRuleCache: [String: [SourceRule]] = [:]

    // 预编译正则
    private static let putPattern: NSRegularExpression = {
        guard let r = try? NSRegularExpression(
            pattern: "@put:(\\{[^}]+?\\})", options: [.caseInsensitive]
        ) else { preconditionFailure("bad putPattern") }
        return r
    }()
    private static let evalPattern: NSRegularExpression = {
        guard let r = try? NSRegularExpression(
            pattern: "@get:\\{[^}]+?\\}|\\{\\{[\\w\\W]*?\\}\\}", options: [.caseInsensitive]
        ) else { preconditionFailure("bad evalPattern") }
        return r
    }()
    private static let regexPattern: NSRegularExpression = {
        guard let r = try? NSRegularExpression(pattern: "\\$\\d{1,2}") else {
            preconditionFailure("bad regexPattern")
        }
        return r
    }()

    public init(ruleData: RuleDataInterface? = nil, source: BookSource? = nil) {
        self.ruleData = ruleData
        self.source = source
    }

    // MARK: - 内容设置

    @discardableResult
    public func setContent(_ content: Any?, baseUrl: String? = nil) -> AnalyzeRule {
        self.content = content
        if let node = content, node is Element || node is Elements {
            isJSON = false
        } else if let content {
            isJSON = NetworkUtils.isJSON(String(describing: content))
        }
        if let baseUrl { self.baseUrl = baseUrl }
        // 内容变更，作废解析器缓存
        cacheToken += 1
        cachedJSoup = nil
        cachedXPath = nil
        cachedJSONPath = nil
        return self
    }

    @discardableResult
    public func setBaseUrl(_ baseUrl: String?) -> AnalyzeRule {
        if let baseUrl { self.baseUrl = baseUrl }
        return self
    }

    @discardableResult
    public func setRedirectUrl(_ url: String) -> String {
        redirectUrl = url
        return url
    }

    // MARK: - 解析器获取

    private func jsoup(for object: Any) throws -> AnalyzeByJSoup {
        if isSameAsContent(object), let cachedJSoup { return cachedJSoup }
        let parser = try AnalyzeByJSoup(doc: object)
        if isSameAsContent(object) { cachedJSoup = parser }
        return parser
    }

    private func xpath(for object: Any) throws -> AnalyzeByXPath {
        if isSameAsContent(object), let cachedXPath { return cachedXPath }
        let parser = try AnalyzeByXPath(doc: object)
        if isSameAsContent(object) { cachedXPath = parser }
        return parser
    }

    private func jsonPath(for object: Any) -> AnalyzeByJSonPath {
        if isSameAsContent(object), let cachedJSONPath { return cachedJSONPath }
        let parser = AnalyzeByJSonPath(json: object)
        if isSameAsContent(object) { cachedJSONPath = parser }
        return parser
    }

    /// 判断传入对象是否就是当前 content（决定能否用缓存）
    private func isSameAsContent(_ object: Any) -> Bool {
        guard let content else { return false }
        if let a = object as? Element, let b = content as? Element { return a === b }
        if let a = object as? Elements, let b = content as? Elements { return a === b }
        if let a = object as? String, let b = content as? String { return a == b }
        return false
    }

    // MARK: - getString

    /// 获取单个字符串结果
    public func getString(
        _ ruleStr: String?,
        mContent: Any? = nil,
        isUrl: Bool = false,
        unescape: Bool = true
    ) -> String {
        guard let ruleStr, !ruleStr.isEmpty else { return "" }
        let rules = splitSourceRuleCacheString(ruleStr)
        return getString(rules, mContent: mContent, isUrl: isUrl, unescape: unescape)
    }

    public func getString(
        _ ruleList: [SourceRule],
        mContent: Any? = nil,
        isUrl: Bool = false,
        unescape: Bool = true
    ) -> String {
        var result: Any?
        let source = mContent ?? content
        guard let source, !ruleList.isEmpty else {
            return isUrl ? (baseUrl ?? "") : ""
        }

        result = source
        for rule in ruleList {
            putRule(rule.putMap)
            rule.makeUpRule(result, analyzer: self)
            guard let current = result else { continue }

            if !rule.rule.isEmpty || rule.replaceRegex.isEmpty {
                switch rule.mode {
                case .js:
                    result = evalJS(rule.rule, result: current)
                case .json:
                    result = jsonPath(for: current).getString(rule.rule)
                case .xPath:
                    result = (try? xpath(for: current).getString(rule.rule)) ?? nil
                case .default:
                    // isUrl 时只取第一个结果，避免多个链接被换行拼接
                    if isUrl {
                        result = (try? jsoup(for: current).getString0(rule.rule)) ?? ""
                    } else {
                        result = (try? jsoup(for: current).getString(rule.rule)) ?? nil
                    }
                case .regex:
                    result = rule.rule
                }
            }
            if result != nil, !rule.replaceRegex.isEmpty {
                result = replaceRegex(String(describing: result!), rule: rule)
            }
        }

        var resultStr = result.map { stringValue(of: $0) } ?? ""
        if unescape, resultStr.contains("&") {
            resultStr = TextFormatter.unescapeHTML(resultStr)
        }
        if isUrl {
            if resultStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return baseUrl ?? ""
            }
            return NetworkUtils.absoluteURL(base: redirectUrl ?? baseUrl, relative: resultStr)
        }
        return resultStr
    }

    // MARK: - getStringList

    public func getStringList(
        _ ruleStr: String?,
        mContent: Any? = nil,
        isUrl: Bool = false
    ) -> [String]? {
        guard let ruleStr, !ruleStr.isEmpty else { return nil }
        let rules = splitSourceRuleCacheString(ruleStr)
        return getStringList(rules, mContent: mContent, isUrl: isUrl)
    }

    public func getStringList(
        _ ruleList: [SourceRule],
        mContent: Any? = nil,
        isUrl: Bool = false
    ) -> [String]? {
        var result: Any?
        let source = mContent ?? content
        guard let source, !ruleList.isEmpty else { return nil }

        result = source
        for rule in ruleList {
            putRule(rule.putMap)
            rule.makeUpRule(result, analyzer: self)
            guard let current = result else { continue }

            if !rule.rule.isEmpty {
                switch rule.mode {
                case .js:
                    result = evalJS(rule.rule, result: current)
                case .json:
                    result = jsonPath(for: current).getStringList(rule.rule)
                case .xPath:
                    result = (try? xpath(for: current).getStringList(rule.rule)) ?? []
                case .default:
                    result = (try? jsoup(for: current).getStringList(rule.rule)) ?? []
                case .regex:
                    result = rule.rule
                }
            }
            if !rule.replaceRegex.isEmpty {
                if let list = result as? [String] {
                    result = list.map { replaceRegex($0, rule: rule) }
                } else if let current = result {
                    result = replaceRegex(stringValue(of: current), rule: rule)
                }
            }
        }

        guard var list = normalizeToList(result) else { return nil }
        if isUrl {
            var urls: [String] = []
            for item in list {
                let absolute = NetworkUtils.absoluteURL(
                    base: redirectUrl ?? baseUrl, relative: item
                )
                if !absolute.isEmpty, !urls.contains(absolute) {
                    urls.append(absolute)
                }
            }
            return urls
        }
        // 去掉纯空白项，避免目录里出现空条目
        list = list.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return list
    }

    private func normalizeToList(_ value: Any?) -> [String]? {
        guard let value else { return nil }
        if let list = value as? [String] { return list }
        if let text = value as? String {
            return text.components(separatedBy: "\n")
        }
        if let list = value as? [Any] { return list.map { stringValue(of: $0) } }
        return [stringValue(of: value)]
    }

    // MARK: - getElement(s)

    /// 获取单个元素（用于详情页 init 规则）
    public func getElement(_ ruleStr: String) -> Any? {
        guard !ruleStr.isEmpty else { return nil }
        var result: Any? = content
        guard result != nil else { return nil }

        let rules = splitSourceRule(ruleStr, allInOne: true)
        for rule in rules {
            putRule(rule.putMap)
            rule.makeUpRule(result, analyzer: self)
            guard let current = result else { continue }
            switch rule.mode {
            case .regex:
                result = AnalyzeByRegex.getElement(
                    stringValue(of: current), regs: splitNotBlank(rule.rule, "&&")
                )
            case .js:
                result = evalJS(rule.rule, result: current)
            case .json:
                result = jsonPath(for: current).getList(rule.rule).first
            case .xPath:
                result = (try? xpath(for: current).getElements(rule.rule)) ?? nil
            case .default:
                result = (try? jsoup(for: current).getElements(rule.rule)) ?? nil
            }
            if !rule.replaceRegex.isEmpty, let current = result {
                result = replaceRegex(stringValue(of: current), rule: rule)
            }
        }
        return result
    }

    /// 获取元素列表（bookList / chapterList）
    public func getElements(_ ruleStr: String) -> [Any] {
        var result: Any? = content
        guard result != nil, !ruleStr.isEmpty else { return [] }

        let rules = splitSourceRule(ruleStr, allInOne: true)
        for rule in rules {
            putRule(rule.putMap)
            rule.makeUpRule(result, analyzer: self)
            guard let current = result else { continue }
            switch rule.mode {
            case .regex:
                result = AnalyzeByRegex.getElements(
                    stringValue(of: current), regs: splitNotBlank(rule.rule, "&&")
                )
            case .js:
                result = evalJS(rule.rule, result: current)
            case .json:
                result = jsonPath(for: current).getList(rule.rule)
            case .xPath:
                // AnalyzeByXPath.getElements 已返回 [Element]
                result = (try? xpath(for: current).getElements(rule.rule)) ?? []
            case .default:
                result = (try? jsoup(for: current).getElements(rule.rule))?.array() ?? []
            }
            if !rule.replaceRegex.isEmpty, let current = result {
                result = replaceRegex(stringValue(of: current), rule: rule)
            }
        }

        if let elements = result as? Elements { return elements.array() }
        if let list = result as? [Any] { return list }
        if let element = result as? Element { return [element] }
        return []
    }

    // MARK: - 变量

    private func putRule(_ map: [String: String]) {
        for (key, value) in map {
            put(key, getString(value))
        }
    }

    @discardableResult
    public func put(_ key: String, _ value: String) -> String {
        ruleData?.putVariable(key, value)
        return value
    }

    public func get(_ key: String) -> String {
        switch key {
        case "bookName":
            if let data = ruleData as? BookRuleData { return data.book.name }
        case "title":
            if let chapter { return chapter.title }
        default:
            break
        }
        return ruleData?.getVariable(key) ?? ""
    }

    // MARK: - JS

    @discardableResult
    public func evalJS(_ script: String, result: Any? = nil) -> Any? {
        var bindings: [String: Any] = [:]
        if let baseUrl { bindings["baseUrl"] = baseUrl }
        if let chapter {
            bindings["title"] = chapter.title
        }
        if let nextChapterUrl { bindings["nextChapterUrl"] = nextChapterUrl }
        if let data = ruleData as? BookRuleData {
            bindings["bookName"] = data.book.name
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

    // MARK: - 正则替换

    /// `##match##replace[##]` 后处理
    private func replaceRegex(_ input: String, rule: SourceRule) -> String {
        guard !rule.replaceRegex.isEmpty else { return input }

        if rule.replaceFirst {
            // 四段式：取第一个匹配并替换，其余丢弃
            guard let regex = try? NSRegularExpression(pattern: rule.replaceRegex) else {
                return rule.replacement
            }
            let ns = input as NSString
            guard let match = regex.firstMatch(
                in: input, range: NSRange(location: 0, length: ns.length)
            ) else { return "" }
            let matched = ns.substring(with: match.range)
            let matchedNS = matched as NSString
            return regex.stringByReplacingMatches(
                in: matched,
                range: NSRange(location: 0, length: matchedNS.length),
                withTemplate: rule.replacement
            )
        }

        guard let regex = try? NSRegularExpression(pattern: rule.replaceRegex) else {
            // 正则不合法时退化为字面替换。
            return input.replacingOccurrences(of: rule.replaceRegex, with: rule.replacement)
        }
        let ns = input as NSString
        return regex.stringByReplacingMatches(
            in: input,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: rule.replacement
        )
    }

    // MARK: - 规则拆分

    public func splitSourceRuleCacheString(_ ruleStr: String?) -> [SourceRule] {
        guard let ruleStr, !ruleStr.isEmpty else { return [] }
        if let cached = stringRuleCache[ruleStr] { return cached }
        let rules = splitSourceRule(ruleStr)
        stringRuleCache[ruleStr] = rules
        return rules
    }

    /// 把规则串按 `@js:` / `<js>` 切成多段。
    public func splitSourceRule(_ ruleStr: String?, allInOne: Bool = false) -> [SourceRule] {
        guard let ruleStr, !ruleStr.isEmpty else { return [] }

        var ruleList: [SourceRule] = []
        var mode: Mode = .default
        var start = 0

        // 仅首字符为 ':' 时视为 AllInOne 正则模式
        if allInOne, ruleStr.hasPrefix(":") {
            mode = .regex
            isRegex = true
            start = 1
        } else if isRegex {
            mode = .regex
        }

        let ns = ruleStr as NSString
        let matches = Self.jsOnlyMatches(in: ruleStr)
        for match in matches {
            if match.range.location > start {
                let tmp = ns
                    .substring(with: NSRange(location: start, length: match.range.location - start))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !tmp.isEmpty {
                    ruleList.append(SourceRule(tmp, mode: mode, isJSON: isJSON, analyzer: self))
                }
            }
            var script = ""
            for group in [1, 2] where group < match.numberOfRanges {
                let range = match.range(at: group)
                if range.location != NSNotFound {
                    script = ns.substring(with: range)
                    break
                }
            }
            ruleList.append(SourceRule(script, mode: .js, isJSON: isJSON, analyzer: self))
            start = match.range.location + match.range.length
        }

        if ns.length > start {
            let tmp = ns.substring(from: start)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !tmp.isEmpty {
                ruleList.append(SourceRule(tmp, mode: mode, isJSON: isJSON, analyzer: self))
            }
        }
        return ruleList
    }

    private static func jsOnlyMatches(in text: String) -> [NSTextCheckingResult] {
        let ns = text as NSString
        return AnalyzeUrl.jsOnlyPattern.matches(
            in: text, range: NSRange(location: 0, length: ns.length)
        )
    }

    /// 分离 `@put:{...}`，返回剩余规则
    fileprivate static func splitPutRule(
        _ ruleStr: String, putMap: inout [String: String]
    ) -> String {
        var result = ruleStr
        while true {
            let ns = result as NSString
            guard let match = putPattern.firstMatch(
                in: result, range: NSRange(location: 0, length: ns.length)
            ), match.numberOfRanges > 1 else { break }

            let json = ns.substring(with: match.range(at: 1))
            for (key, value) in parsePutJSON(json) {
                putMap[key] = value
            }
            result = ns.replacingCharacters(in: match.range, with: "")
        }
        return result
    }

    /// 解析 `@put:{...}` 内的键值对。
    ///
    /// 真实书源里这段常写成不带引号的宽松 JSON，例如
    /// `@put:{bookName:tag.h3@text}`、`@put:{key:"class.a@text"}`。
    /// 此类宽松 JSON 中的键值可能没有引号，而 `JSONSerialization` 是严格模式会直接失败，
    /// 因此这里先尝试严格解析，失败再退化为宽松键值拆分——否则大量书源的
    /// 变量传递（书名、章节 token 等）会静默失效。
    static func parsePutJSON(_ json: String) -> [String: String] {
        // 1) 严格 JSON
        if let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict.mapValues { String(describing: $0) }
        }

        // 2) 宽松解析：去掉外层大括号，按顶层逗号切分 k:v
        var body = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("{") { body = String(body.dropFirst()) }
        if body.hasSuffix("}") { body = String(body.dropLast()) }

        var result: [String: String] = [:]
        for pair in splitTopLevel(body, separator: ",") {
            // 只按第一个冒号切分：值本身可能含 `:`（如 @XPath: 规则）
            guard let colon = pair.firstIndex(of: ":") else { continue }
            let rawKey = String(pair[pair.startIndex..<colon])
            let rawValue = String(pair[pair.index(after: colon)...])
            let key = unquote(rawKey)
            let value = unquote(rawValue)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    /// 按分隔符切分，但忽略括号 / 引号内部的分隔符
    private static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inSingle = false
        var inDouble = false

        for ch in text {
            if ch == "'" && !inDouble { inSingle.toggle() }
            if ch == "\"" && !inSingle { inDouble.toggle() }
            if !inSingle && !inDouble {
                if ch == "{" || ch == "[" || ch == "(" { depth += 1 }
                if ch == "}" || ch == "]" || ch == ")" { depth -= 1 }
                if ch == separator && depth == 0 {
                    parts.append(current)
                    current = ""
                    continue
                }
            }
            current.append(ch)
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// 去掉首尾空白与包裹引号
    private static func unquote(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2 {
            let first = value.first
            let last = value.last
            if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                value = String(value.dropFirst().dropLast())
            }
        }
        return value
    }

    // MARK: - 工具

    func stringValue(of value: Any) -> String {
        switch value {
        case let text as String: return text
        case let list as [String]: return list.joined(separator: "\n")
        case let number as Int: return String(number)
        case let number as Double:
            return number.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", number) : String(number)
        case let flag as Bool: return flag ? "true" : "false"
        case let element as Element: return (try? element.outerHtml()) ?? ""
        case let elements as Elements: return (try? elements.outerHtml()) ?? ""
        case let list as [Any]: return list.map { stringValue(of: $0) }.joined(separator: "\n")
        default: return String(describing: value)
        }
    }

    private func splitNotBlank(_ text: String, _ separator: String) -> [String] {
        text.components(separatedBy: separator)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - SourceRule

    /// 单条规则。
    public final class SourceRule {
        fileprivate(set) public var rule: String
        fileprivate(set) var mode: Mode
        fileprivate(set) var replaceRegex = ""
        fileprivate(set) var replacement = ""
        fileprivate(set) var replaceFirst = false
        fileprivate(set) var putMap: [String: String] = [:]

        /// 规则参数与类型，用于 makeUpRule 时按序回填
        private var ruleParam: [String] = []
        private var ruleType: [Int] = []
        private static let getRuleType = -2
        private static let jsRuleType = -1
        private static let defaultRuleType = 0

        /// 原始规则，makeUpRule 每次从它重新展开，避免多次调用相互污染
        private let originRule: String

        init(_ ruleStr: String, mode: Mode, isJSON: Bool, analyzer: AnalyzeRule) {
            var mode = mode
            var rule: String

            // 识别规则类型前缀
            switch true {
            case mode == .js || mode == .regex:
                rule = ruleStr
            case ruleStr.lowercased().hasPrefix("@css:"):
                mode = .default
                rule = ruleStr
            case ruleStr.hasPrefix("@@"):
                mode = .default
                rule = String(ruleStr.dropFirst(2))
            case ruleStr.lowercased().hasPrefix("@xpath:"):
                mode = .xPath
                rule = String(ruleStr.dropFirst(7))
            case ruleStr.lowercased().hasPrefix("@json:"):
                mode = .json
                rule = String(ruleStr.dropFirst(6))
            case isJSON || ruleStr.hasPrefix("$.") || ruleStr.hasPrefix("$["):
                mode = .json
                rule = ruleStr
            case ruleStr.hasPrefix("/"):
                // XPath 特征明显，无需前缀
                mode = .xPath
                rule = ruleStr
            default:
                rule = ruleStr
            }

            // 分离 @put
            var putMap: [String: String] = [:]
            rule = AnalyzeRule.splitPutRule(rule, putMap: &putMap)

            self.mode = mode
            self.rule = rule
            self.originRule = rule
            self.putMap = putMap

            // 拆分 @get:{} 与 {{js}}
            parseEval(rule)
        }

        private func parseEval(_ rule: String) {
            var start = 0
            let ns = rule as NSString
            let matches = AnalyzeRule.evalPattern.matches(
                in: rule, range: NSRange(location: 0, length: ns.length)
            )
            guard !matches.isEmpty else {
                splitRegex(rule)
                return
            }

            // 首个 {{}} 之前若不含 ##，整体按 regex 模式处理
            let firstStart = matches[0].range.location
            let head = ns.substring(with: NSRange(location: 0, length: firstStart))
            if mode != .js, mode != .regex, firstStart == 0 || !head.contains("##") {
                mode = .regex
            }

            for match in matches {
                if match.range.location > start {
                    let tmp = ns.substring(
                        with: NSRange(location: start, length: match.range.location - start)
                    )
                    splitRegex(tmp)
                }
                let token = ns.substring(with: match.range)
                if token.lowercased().hasPrefix("@get:") {
                    ruleType.append(Self.getRuleType)
                    // 去掉 "@get:{" 与结尾 "}"
                    let inner = String(token.dropFirst(6).dropLast())
                    ruleParam.append(inner)
                } else if token.hasPrefix("{{") {
                    ruleType.append(Self.jsRuleType)
                    ruleParam.append(String(token.dropFirst(2).dropLast(2)))
                } else {
                    splitRegex(token)
                }
                start = match.range.location + match.range.length
            }
            if ns.length > start {
                splitRegex(ns.substring(from: start))
            }
        }

        /// 拆分 `$1`..`$99` 分组引用
        private func splitRegex(_ ruleStr: String) {
            var start = 0
            let parts = ruleStr.components(separatedBy: "##")
            let head = parts.first ?? ruleStr
            let headNS = head as NSString
            let matches = AnalyzeRule.regexPattern.matches(
                in: head, range: NSRange(location: 0, length: headNS.length)
            )

            if !matches.isEmpty {
                if mode != .js, mode != .regex { mode = .regex }
                let ns = ruleStr as NSString
                for match in matches {
                    if match.range.location > start {
                        let tmp = ns.substring(
                            with: NSRange(location: start, length: match.range.location - start)
                        )
                        ruleType.append(Self.defaultRuleType)
                        ruleParam.append(tmp)
                    }
                    let token = ns.substring(with: match.range)
                    ruleType.append(Int(token.dropFirst()) ?? 0)
                    ruleParam.append(token)
                    start = match.range.location + match.range.length
                }
            }
            let ns = ruleStr as NSString
            if ns.length > start {
                ruleType.append(Self.defaultRuleType)
                ruleParam.append(ns.substring(from: start))
            }
        }

        /// 回填 `@get:{}` / `{{js}}` / `$n`，并分离 `##` 后处理段
        func makeUpRule(_ result: Any?, analyzer: AnalyzeRule) {
            var infoVal = ""
            if !ruleParam.isEmpty {
                var index = ruleParam.count
                while index > 0 {
                    index -= 1
                    let regType = ruleType[index]
                    if regType > Self.defaultRuleType {
                        // $n：从正则分组结果里取
                        if let list = result as? [String], list.count > regType {
                            infoVal = list[regType] + infoVal
                        } else {
                            infoVal = ruleParam[index] + infoVal
                        }
                    } else if regType == Self.jsRuleType {
                        let param = ruleParam[index]
                        if Self.isRule(param) {
                            // {{@css:...}} 这类内嵌规则，递归当规则处理
                            let sub = SourceRule(
                                param, mode: .default, isJSON: false, analyzer: analyzer
                            )
                            infoVal = analyzer.getString([sub], mContent: result) + infoVal
                        } else {
                            let value = analyzer.evalJS(param, result: result)
                            infoVal = (AnalyzeUrl.stringify(value) ?? "") + infoVal
                        }
                    } else if regType == Self.getRuleType {
                        infoVal = analyzer.get(ruleParam[index]) + infoVal
                    } else {
                        infoVal = ruleParam[index] + infoVal
                    }
                }
                rule = infoVal
            } else {
                // 无参数时用原始规则，保证重复调用行为一致
                rule = originRule
            }

            // 分离 ## 后处理
            let parts = rule.components(separatedBy: "##")
            rule = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            replaceRegex = parts.count > 1 ? parts[1] : ""
            replacement = parts.count > 2 ? parts[2] : ""
            replaceFirst = parts.count > 3
        }

        /// 判断 `{{}}` 内容是规则还是 JS。
        private static func isRule(_ ruleStr: String) -> Bool {
            ruleStr.hasPrefix("@")
                || ruleStr.hasPrefix("$.")
                || ruleStr.hasPrefix("$[")
                || ruleStr.hasPrefix("//")
        }

        var paramSize: Int { ruleParam.count }
    }
}
