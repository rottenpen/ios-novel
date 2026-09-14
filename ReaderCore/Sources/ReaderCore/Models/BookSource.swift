// Swift 实现及修改：Yuedu 项目，2026-09-14。
// 来源与许可见仓库根目录 THIRD_PARTY_NOTICES.md（GPL-3.0）。
import Foundation

// MARK: - Flexible decoding helpers

/// 书源 JSON 中，规则字段（ruleSearch / ruleToc / ...）既可能是嵌套对象，
/// 也可能是被转义成字符串的 JSON（旧版导出格式）。这里统一兼容两种形态。
/// 解码时统一将两种形式转换为规则结构。
@propertyWrapper
public struct FlexibleJSON<T: Codable & Sendable>: Codable, Sendable {
    public var wrappedValue: T?

    public init(wrappedValue: T?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
            return
        }
        // 形态一：嵌套对象
        if let value = try? container.decode(T.self) {
            wrappedValue = value
            return
        }
        // 形态二：转义后的 JSON 字符串
        if let raw = try? container.decode(String.self) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                wrappedValue = nil
                return
            }
            if let data = trimmed.data(using: .utf8),
               let value = try? JSONDecoder().decode(T.self, from: data) {
                wrappedValue = value
                return
            }
        }
        wrappedValue = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(wrappedValue)
        } else {
            try container.encodeNil()
        }
    }
}

extension KeyedDecodingContainer {
    public func decode<T: Codable & Sendable>(
        _ type: FlexibleJSON<T>.Type,
        forKey key: Key
    ) throws -> FlexibleJSON<T> {
        try decodeIfPresent(type, forKey: key) ?? FlexibleJSON<T>(wrappedValue: nil)
    }
}

/// 书源 JSON 中 Bool 字段可能写成 true / "true" / 1 / "1"。
@propertyWrapper
public struct FlexibleBool: Codable, Sendable {
    public var wrappedValue: Bool?

    public init(wrappedValue: Bool?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
            return
        }
        if let value = try? container.decode(Bool.self) {
            wrappedValue = value
        } else if let value = try? container.decode(Int.self) {
            wrappedValue = value != 0
        } else if let value = try? container.decode(String.self) {
            switch value.lowercased() {
            case "true", "1", "yes": wrappedValue = true
            case "false", "0", "no": wrappedValue = false
            default: wrappedValue = nil
            }
        } else {
            wrappedValue = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(wrappedValue)
        } else {
            try container.encodeNil()
        }
    }
}

extension KeyedDecodingContainer {
    public func decode(
        _ type: FlexibleBool.Type,
        forKey key: Key
    ) throws -> FlexibleBool {
        try decodeIfPresent(type, forKey: key) ?? FlexibleBool(wrappedValue: nil)
    }
}

/// 数字字段可能是 Int / String / Double。
@propertyWrapper
public struct FlexibleInt: Codable, Sendable {
    public var wrappedValue: Int?

    public init(wrappedValue: Int?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
            return
        }
        if let value = try? container.decode(Int.self) {
            wrappedValue = value
        } else if let value = try? container.decode(Double.self) {
            wrappedValue = Int(value)
        } else if let value = try? container.decode(String.self) {
            wrappedValue = Int(value.trimmingCharacters(in: .whitespaces))
        } else {
            wrappedValue = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(wrappedValue)
        } else {
            try container.encodeNil()
        }
    }
}

extension KeyedDecodingContainer {
    public func decode(
        _ type: FlexibleInt.Type,
        forKey key: Key
    ) throws -> FlexibleInt {
        try decodeIfPresent(type, forKey: key) ?? FlexibleInt(wrappedValue: nil)
    }
}

// MARK: - Rule models

/// 搜索和发现共用的书籍列表字段。
public protocol BookListRuleProtocol {
    var bookList: String? { get }
    var name: String? { get }
    var author: String? { get }
    var intro: String? { get }
    var kind: String? { get }
    var lastChapter: String? { get }
    var updateTime: String? { get }
    var bookUrl: String? { get }
    var coverUrl: String? { get }
    var wordCount: String? { get }
}

/// 搜索规则
public struct SearchRule: Codable, Sendable, BookListRuleProtocol {
    public var checkKeyWord: String?
    public var bookList: String?
    public var name: String?
    public var author: String?
    public var intro: String?
    public var kind: String?
    public var lastChapter: String?
    public var updateTime: String?
    public var bookUrl: String?
    public var coverUrl: String?
    public var wordCount: String?

    public init() {}
}

/// 发现规则
public struct ExploreRule: Codable, Sendable, BookListRuleProtocol {
    public var bookList: String?
    public var name: String?
    public var author: String?
    public var intro: String?
    public var kind: String?
    public var lastChapter: String?
    public var updateTime: String?
    public var bookUrl: String?
    public var coverUrl: String?
    public var wordCount: String?

    public init() {}
}

/// 书籍详情规则
public struct BookInfoRule: Codable, Sendable {
    public var initRule: String?
    public var name: String?
    public var author: String?
    public var intro: String?
    public var kind: String?
    public var lastChapter: String?
    public var updateTime: String?
    public var coverUrl: String?
    public var tocUrl: String?
    public var wordCount: String?
    public var canReName: String?
    public var downloadUrls: String?

    // JSON 中该字段名为 `init`，是 Swift 关键字，需映射。
    enum CodingKeys: String, CodingKey {
        case initRule = "init"
        case name, author, intro, kind, lastChapter, updateTime
        case coverUrl, tocUrl, wordCount, canReName, downloadUrls
    }

    public init() {}
}

/// 目录规则
public struct TocRule: Codable, Sendable {
    public var preUpdateJs: String?
    public var chapterList: String?
    public var chapterName: String?
    public var chapterUrl: String?
    public var formatJs: String?
    public var isVolume: String?
    public var isVip: String?
    public var isPay: String?
    public var updateTime: String?
    public var nextTocUrl: String?

    public init() {}
}

/// 正文规则
public struct ContentRule: Codable, Sendable {
    public var content: String?
    public var title: String?
    public var nextContentUrl: String?
    public var webJs: String?
    public var sourceRegex: String?
    public var replaceRegex: String?
    public var imageStyle: String?
    public var imageDecode: String?
    public var payAction: String?

    public init() {}
}

// MARK: - BookSource

/// 书源类型。
public enum BookSourceType: Int, Codable, Sendable {
    case text = 0
    case audio = 1
    case image = 2
    case file = 3
}

/// 书源定义，保留兼容格式的字段名。
public struct BookSource: Codable, Sendable, Identifiable, Hashable {
    public var bookSourceUrl: String = ""
    public var bookSourceName: String = ""
    public var bookSourceGroup: String?
    @FlexibleInt public var bookSourceTypeRaw: Int?
    public var bookUrlPattern: String?
    @FlexibleInt public var customOrder: Int?
    @FlexibleBool public var enabled: Bool?
    @FlexibleBool public var enabledExplore: Bool?
    public var jsLib: String?
    @FlexibleBool public var enabledCookieJar: Bool?
    public var concurrentRate: String?
    public var header: String?
    public var loginUrl: String?
    public var loginUi: String?
    public var loginCheckJs: String?
    public var coverDecodeJs: String?
    public var bookSourceComment: String?
    public var variableComment: String?
    public var lastUpdateTime: Double?
    public var respondTime: Double?
    @FlexibleInt public var weight: Int?
    public var exploreUrl: String?
    public var exploreScreen: String?
    public var searchUrl: String?

    @FlexibleJSON public var ruleExplore: ExploreRule?
    @FlexibleJSON public var ruleSearch: SearchRule?
    @FlexibleJSON public var ruleBookInfo: BookInfoRule?
    @FlexibleJSON public var ruleToc: TocRule?
    @FlexibleJSON public var ruleContent: ContentRule?

    enum CodingKeys: String, CodingKey {
        case bookSourceUrl, bookSourceName, bookSourceGroup
        case bookSourceTypeRaw = "bookSourceType"
        case bookUrlPattern, customOrder, enabled, enabledExplore
        case jsLib, enabledCookieJar, concurrentRate, header
        case loginUrl, loginUi, loginCheckJs, coverDecodeJs
        case bookSourceComment, variableComment, lastUpdateTime, respondTime, weight
        case exploreUrl, exploreScreen, searchUrl
        case ruleExplore, ruleSearch, ruleBookInfo, ruleToc, ruleContent
    }

    public init() {}

    public var id: String { bookSourceUrl }

    public var sourceType: BookSourceType {
        BookSourceType(rawValue: bookSourceTypeRaw ?? 0) ?? .text
    }

    public var isEnabled: Bool { enabled ?? true }
    public var isExploreEnabled: Bool { enabledExplore ?? true }

    /// 书源分组拆分，使用 `,` `;` 及中文标点分隔。
    public var groups: [String] {
        guard let bookSourceGroup, !bookSourceGroup.isEmpty else { return [] }
        return bookSourceGroup
            .components(separatedBy: CharacterSet(charactersIn: ",;，；、 "))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bookSourceUrl)
    }

    public static func == (lhs: BookSource, rhs: BookSource) -> Bool {
        lhs.bookSourceUrl == rhs.bookSourceUrl
    }

    /// 解析请求头，支持 JSON 对象字符串，或 `{{js}}` 形式（js 部分由引擎预处理后传入）。
    ///
    /// 真实书源里 header 常写成**单引号 JSON**（如 `{'User-Agent': 'xxx'}`），
    /// 宽松 JSON 可包含无引号字段，而 `JSONSerialization` 严格模式会失败。
    /// 若不兼容，这类书源会丢掉自定义 UA / Referer，导致站点直接返回 403 —— 必须容错。
    public func headerMap() -> [String: String] {
        var map: [String: String] = ["User-Agent": AppConstants.defaultUserAgent]
        guard let header, !header.isEmpty else { return map }

        for (key, value) in Self.parseLooseJSONObject(header) {
            map[key] = value
        }
        return map
    }

    /// 宽松解析 JSON 对象字符串：先严格解析，失败再按单引号 / 无引号形式解析。
    static func parseLooseJSONObject(_ text: String) -> [String: String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }

        // 1) 严格 JSON
        if let data = trimmed.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict.mapValues { String(describing: $0) }
        }

        // 2) 单引号转双引号后再试（仅替换作为分隔符的单引号）
        if let converted = convertSingleQuotes(trimmed)?.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: converted) as? [String: Any] {
            return dict.mapValues { String(describing: $0) }
        }

        // 3) 最后退化为手工键值拆分
        var body = trimmed
        if body.hasPrefix("{") { body = String(body.dropFirst()) }
        if body.hasSuffix("}") { body = String(body.dropLast()) }

        var result: [String: String] = [:]
        var current = ""
        var depth = 0
        var inQuote: Character?
        var parts: [String] = []

        for ch in body {
            if let quote = inQuote {
                if ch == quote { inQuote = nil }
            } else if ch == "'" || ch == "\"" {
                inQuote = ch
            } else if ch == "{" || ch == "[" {
                depth += 1
            } else if ch == "}" || ch == "]" {
                depth -= 1
            } else if ch == ",", depth == 0 {
                parts.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { parts.append(current) }

        for pair in parts {
            guard let colon = pair.firstIndex(of: ":") else { continue }
            let key = stripQuotes(String(pair[pair.startIndex..<colon]))
            let value = stripQuotes(String(pair[pair.index(after: colon)...]))
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    /// 把 JSON 里的单引号字符串转成双引号；已有的双引号内容原样保留
    private static func convertSingleQuotes(_ text: String) -> String? {
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

    private static func stripQuotes(_ text: String) -> String {
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

    /// 并发限流配置，格式如 "0"、"1000"、"5/1000"（次数/毫秒）。
    public var concurrentLimit: (count: Int, intervalMillis: Int)? {
        guard let concurrentRate, !concurrentRate.isEmpty else { return nil }
        let parts = concurrentRate.split(separator: "/")
        if parts.count == 2 {
            guard let count = Int(parts[0]), let interval = Int(parts[1]), count > 0 else {
                return nil
            }
            return (count, interval)
        }
        guard let interval = Int(concurrentRate), interval > 0 else { return nil }
        return (1, interval)
    }
}

public enum AppConstants {
    public static let defaultUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
}
