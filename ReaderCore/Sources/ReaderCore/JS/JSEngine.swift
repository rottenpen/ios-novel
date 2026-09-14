// Swift 实现及修改：Yuedu 项目，2026-09-14。
// 来源与许可见仓库根目录 THIRD_PARTY_NOTICES.md（GPL-3.0）。
import Foundation
import JavaScriptCore
import CryptoKit

/// 每次求值使用独立 JavaScriptCore 上下文，宿主接口提供网络、变量和缓存能力。
/// 依赖浏览器验证、文件系统或远程脚本导入的接口返回空值，并记录能力缺失。
public final class JSEngine: @unchecked Sendable {

    public static let shared = JSEngine()

    private let queue = DispatchQueue(label: "com.yuedu.jsengine")

    private init() {}

    /// 每次求值使用独立 context，避免书源之间的全局变量污染
    public func createContext(
        source: BookSource? = nil,
        variableStore: VariableStore? = nil
    ) -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, exception in
            if let exception {
                JSLog.shared.append("脚本执行失败：\(exception.forProperty("name")?.toString() ?? "异常")")
            }
        }
        installJavaObject(in: context, source: source, variableStore: variableStore)
        return context
    }

    /// 执行 JS 并返回结果
    public func evaluate(
        _ script: String,
        result: Any? = nil,
        source: BookSource? = nil,
        baseUrl: String? = nil,
        variableStore: VariableStore? = nil,
        extraBindings: [String: Any] = [:]
    ) -> Any? {
        let context = createContext(source: source, variableStore: variableStore)

        // 注入标准绑定
        if let result {
            context.setObject(jsValue(from: result, in: context), forKeyedSubscript: "result" as NSString)
        } else {
            context.setObject(JSValue(nullIn: context), forKeyedSubscript: "result" as NSString)
        }
        if let baseUrl {
            context.setObject(baseUrl as NSString, forKeyedSubscript: "baseUrl" as NSString)
        }
        if let source {
            context.setObject(source.bookSourceUrl as NSString, forKeyedSubscript: "sourceUrl" as NSString)
            if let key = source.jsLib, !key.isEmpty {
                context.evaluateScript(key)
            }
        }
        for (key, value) in extraBindings {
            context.setObject(jsValue(from: value, in: context), forKeyedSubscript: key as NSString)
        }

        guard let value = context.evaluateScript(script) else { return nil }
        return unwrap(value)
    }

    /// 将 JS 结果转成 Swift 值
    public func unwrap(_ value: JSValue) -> Any? {
        if value.isNull || value.isUndefined { return nil }
        if value.isString { return value.toString() }
        if value.isBoolean { return value.toBool() }
        if value.isNumber {
            let d = value.toDouble()
            // 整数值的 Double 去掉 .0
            if d.truncatingRemainder(dividingBy: 1) == 0 && abs(d) < 1e15 {
                return Int(d)
            }
            return d
        }
        if value.isArray {
            return value.toArray()
        }
        if value.isObject {
            if let dict = value.toDictionary() { return dict }
            return value.toString()
        }
        return value.toString()
    }

    private func jsValue(from value: Any, in context: JSContext) -> Any {
        switch value {
        case is NSNull: return NSNull()
        case let array as [Any]: return array.map { jsValue(from: $0, in: context) }
        case let object as [String: Any]: return object.mapValues { jsValue(from: $0, in: context) }
        case let number as NSNumber: return number
        case let str as String: return str as NSString
        case let num as Int: return NSNumber(value: num)
        case let num as Double: return NSNumber(value: num)
        case let flag as Bool: return NSNumber(value: flag)
        default: return String(describing: value) as NSString
        }
    }

    // MARK: - java object

    private func installJavaObject(
        in context: JSContext,
        source: BookSource?,
        variableStore: VariableStore?
    ) {
        let java = JSValue(newObjectIn: context)!

        // ---- 日志 ----
        let log: @convention(block) (String) -> String = { msg in
            JSLog.shared.append(msg)
            return msg
        }
        java.setObject(log, forKeyedSubscript: "log" as NSString)
        java.setObject(log, forKeyedSubscript: "toast" as NSString)
        java.setObject(log, forKeyedSubscript: "longToast" as NSString)

        // ---- 网络请求（同步语义，书源 JS 依赖同步返回）----
        let ajax: @convention(block) (JSValue) -> String? = { urlValue in
            let urlStr: String
            if urlValue.isArray, let arr = urlValue.toArray(), let first = arr.first {
                urlStr = String(describing: first)
            } else {
                urlStr = urlValue.toString() ?? ""
            }
            return SyncHTTP.shared.requestString(rule: urlStr, source: source)
        }
        java.setObject(ajax, forKeyedSubscript: "ajax" as NSString)

        let get: @convention(block) (String, JSValue?) -> [String: Any]? = { url, headers in
            let headerMap = headers?.toDictionary() as? [String: String]
            let body = SyncHTTP.shared.request(
                url: url, method: "GET", body: nil, headers: headerMap, source: source
            )
            return body
        }
        java.setObject(get, forKeyedSubscript: "_networkGet" as NSString)

        let post: @convention(block) (String, String, JSValue?) -> [String: Any]? = {
            url, body, headers in
            let headerMap = headers?.toDictionary() as? [String: String]
            return SyncHTTP.shared.request(
                url: url, method: "POST", body: body, headers: headerMap, source: source
            )
        }
        java.setObject(post, forKeyedSubscript: "post" as NSString)

        let connect: @convention(block) (String) -> [String: Any]? = { rule in
            guard let text = SyncHTTP.shared.requestString(rule: rule, source: source) else {
                return nil
            }
            return ["body": text]
        }
        java.setObject(connect, forKeyedSubscript: "connect" as NSString)

        let head: @convention(block) (String, JSValue?) -> [String: Any]? = { url, headers in
            let headerMap = headers?.toDictionary() as? [String: String]
            return SyncHTTP.shared.request(
                url: url, method: "HEAD", body: nil, headers: headerMap, source: source
            )
        }
        java.setObject(head, forKeyedSubscript: "head" as NSString)

        // ---- Base64 ----
        let base64Encode: @convention(block) (String) -> String? = { str in
            str.data(using: .utf8)?.base64EncodedString()
        }
        java.setObject(base64Encode, forKeyedSubscript: "base64Encode" as NSString)

        let base64Decode: @convention(block) (String) -> String? = { str in
            guard let data = Self.base64Data(from: str) else { return nil }
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
        }
        java.setObject(base64Decode, forKeyedSubscript: "base64Decode" as NSString)

        let base64DecodeToByteArray: @convention(block) (String) -> [UInt8]? = { str in
            guard let data = Self.base64Data(from: str) else { return nil }
            return [UInt8](data)
        }
        java.setObject(
            base64DecodeToByteArray, forKeyedSubscript: "base64DecodeToByteArray" as NSString
        )

        // ---- Hex ----
        let hexEncodeToString: @convention(block) (String) -> String? = { str in
            str.data(using: .utf8)?.map { String(format: "%02x", $0) }.joined()
        }
        java.setObject(hexEncodeToString, forKeyedSubscript: "hexEncodeToString" as NSString)

        let hexDecodeToString: @convention(block) (String) -> String? = { hex in
            guard let data = Self.hexData(from: hex) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        java.setObject(hexDecodeToString, forKeyedSubscript: "hexDecodeToString" as NSString)

        let hexDecodeToByteArray: @convention(block) (String) -> [UInt8]? = { hex in
            guard let data = Self.hexData(from: hex) else { return nil }
            return [UInt8](data)
        }
        java.setObject(
            hexDecodeToByteArray, forKeyedSubscript: "hexDecodeToByteArray" as NSString
        )

        // ---- 字节与字符串 ----
        let strToBytes: @convention(block) (String, JSValue?) -> [UInt8]? = { str, charset in
            let encName = charset?.isString == true ? charset?.toString() : nil
            let encoding = Self.encoding(from: encName) ?? .utf8
            return (str.data(using: encoding)).map { [UInt8]($0) }
        }
        java.setObject(strToBytes, forKeyedSubscript: "strToBytes" as NSString)

        let bytesToStr: @convention(block) (JSValue, JSValue?) -> String? = { bytes, charset in
            guard let arr = bytes.toArray() as? [NSNumber] else { return nil }
            let data = Data(arr.map { $0.uint8Value })
            let encName = charset?.isString == true ? charset?.toString() : nil
            let encoding = Self.encoding(from: encName) ?? .utf8
            return String(data: data, encoding: encoding)
        }
        java.setObject(bytesToStr, forKeyedSubscript: "bytesToStr" as NSString)

        let encodeURI: @convention(block) (String, JSValue?) -> String? = { str, charset in
            let encName = charset?.isString == true ? charset?.toString() : nil
            if let encName, encName.lowercased().contains("gb") {
                return Self.gbkPercentEncode(str)
            }
            return str.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))
            )
        }
        java.setObject(encodeURI, forKeyedSubscript: "encodeURI" as NSString)

        let utf8ToGbk: @convention(block) (String) -> String? = { str in
            Self.gbkPercentEncode(str)
        }
        java.setObject(utf8ToGbk, forKeyedSubscript: "utf8ToGbk" as NSString)

        // ---- 摘要与加密（常用子集）----
        let digestHex: @convention(block) (String, String) -> String? = { data, algorithm in
            Self.digestHex(data, algorithm: algorithm)
        }
        java.setObject(digestHex, forKeyedSubscript: "digestHex" as NSString)
        java.setObject(digestHex, forKeyedSubscript: "md5Encode" as NSString)

        let md5: @convention(block) (String) -> String? = { str in
            Self.digestHex(str, algorithm: "MD5")
        }
        java.setObject(md5, forKeyedSubscript: "md5Encode16" as NSString)

        // ---- HTML / 文本处理 ----
        let htmlFormat: @convention(block) (String) -> String = { str in
            TextFormatter.formatHTML(str)
        }
        java.setObject(htmlFormat, forKeyedSubscript: "htmlFormat" as NSString)

        let t2s: @convention(block) (String) -> String = { $0 }
        java.setObject(t2s, forKeyedSubscript: "t2s" as NSString)
        java.setObject(t2s, forKeyedSubscript: "s2t" as NSString)

        let timeFormat: @convention(block) (JSValue) -> String = { value in
            let millis = value.toDouble()
            let date = Date(timeIntervalSince1970: millis / 1000)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.string(from: date)
        }
        java.setObject(timeFormat, forKeyedSubscript: "timeFormat" as NSString)

        let toNumChapter: @convention(block) (String) -> String = { str in
            TextFormatter.chineseNumbersToArabic(str)
        }
        java.setObject(toNumChapter, forKeyedSubscript: "toNumChapter" as NSString)

        let randomUUID: @convention(block) () -> String = {
            UUID().uuidString
        }
        java.setObject(randomUUID, forKeyedSubscript: "randomUUID" as NSString)

        let toURL: @convention(block) (String, JSValue?) -> String = { url, base in
            let baseStr = base?.isString == true ? (base?.toString() ?? "") : ""
            return NetworkUtils.absoluteURL(base: baseStr, relative: url)
        }
        java.setObject(toURL, forKeyedSubscript: "toURL" as NSString)

        // ---- 缓存与自定义变量 ----
        let cacheGet: @convention(block) (String) -> String? = { key in
            CacheManager.shared.get(key)
        }
        java.setObject(cacheGet, forKeyedSubscript: "cacheGet" as NSString)

        let cachePut: @convention(block) (String, String, JSValue?) -> Void = { key, value, ttl in
            let seconds = ttl?.isNumber == true ? Int(ttl?.toInt32() ?? 0) : 0
            CacheManager.shared.put(key, value: value, ttlSeconds: seconds)
        }
        java.setObject(cachePut, forKeyedSubscript: "cachePut" as NSString)

        let getVar: @convention(block) (String) -> String = { key in
            variableStore?.get(key) ?? ""
        }
        java.setObject(getVar, forKeyedSubscript: "_variableGet" as NSString)

        let putVar: @convention(block) (String, String) -> String = { key, value in
            variableStore?.put(key, value)
            return value
        }
        java.setObject(putVar, forKeyedSubscript: "put" as NSString)

        let getSource: @convention(block) () -> [String: Any]? = {
            guard let source else { return nil }
            return [
                "bookSourceUrl": source.bookSourceUrl,
                "bookSourceName": source.bookSourceName
            ]
        }
        java.setObject(getSource, forKeyedSubscript: "getSource" as NSString)

        // ---- 明确不支持的能力：返回 null 并记录，使书源降级而非崩溃 ----
        let unsupportedNames = [
            "webView", "webViewGetSource", "webViewGetOverrideUrl", "getWebViewUA",
            "startBrowser", "startBrowserAwait", "getVerificationCode",
            "queryTTF", "queryBase64TTF", "replaceFont",
            "unzipFile", "unrarFile", "un7zFile", "unArchiveFile",
            "getZipStringContent", "getRarStringContent", "get7zStringContent",
            "getZipByteArrayContent", "getRarByteArrayContent", "get7zByteArrayContent",
            "readFile", "readTxtFile", "getFile", "deleteFile", "downloadFile",
            "cacheFile", "importScript", "getTxtInFolder", "androidId"
        ]
        let unsupported: @convention(block) () -> JSValue? = { [weak context] in
            JSLog.shared.append("此书源使用了 iOS 端暂不支持的能力，已跳过")
            guard let context else { return nil }
            return JSValue(nullIn: context)
        }
        for name in unsupportedNames {
            java.setObject(unsupported, forKeyedSubscript: name as NSString)
        }

        context.setObject(java, forKeyedSubscript: "java" as NSString)
        // 书源用参数数量区分变量读取和带请求头的 HTTP GET。
        context.evaluateScript("""
            java.get = (function(networkGet, variableGet) {
                return function(key, headers) {
                    return arguments.length > 1 ? networkGet(key, headers) : variableGet(key);
                };
            })(java._networkGet, java._variableGet);
            delete java._networkGet;
            delete java._variableGet;
            """)

        let cache = JSValue(newObjectIn: context)!
        cache.setObject(cacheGet, forKeyedSubscript: "get" as NSString)
        cache.setObject(cachePut, forKeyedSubscript: "put" as NSString)
        let cacheDelete: @convention(block) (String) -> Void = { CacheManager.shared.remove($0) }
        cache.setObject(cacheDelete, forKeyedSubscript: "delete" as NSString)
        context.setObject(cache, forKeyedSubscript: "cache" as NSString)

        let cookie = JSValue(newObjectIn: context)!
        let getCookie: @convention(block) (String) -> String = { CookieStore.shared.get($0) }
        let setCookie: @convention(block) (String, String) -> Void = { url, value in
            CookieStore.shared.set(url, cookie: value)
        }
        let removeCookie: @convention(block) (String) -> Void = { CookieStore.shared.remove($0) }
        let getKey: @convention(block) (String, String) -> String = { url, key in
            CookieStore.shared.get(url).split(separator: ";").compactMap { part -> String? in
                let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return pair.count == 2 && pair[0] == key ? pair[1] : nil
            }.first ?? ""
        }
        cookie.setObject(getCookie, forKeyedSubscript: "getCookie" as NSString)
        cookie.setObject(setCookie, forKeyedSubscript: "setCookie" as NSString)
        cookie.setObject(setCookie, forKeyedSubscript: "replaceCookie" as NSString)
        cookie.setObject(removeCookie, forKeyedSubscript: "removeCookie" as NSString)
        cookie.setObject(getKey, forKeyedSubscript: "getKey" as NSString)
        context.setObject(cookie, forKeyedSubscript: "cookie" as NSString)
    }

    // MARK: - Helpers

    static func base64Data(from str: String) -> Data? {
        var s = str.trimmingCharacters(in: .whitespacesAndNewlines)
        // 兼容 URL safe 与缺省 padding
        s = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 {
            s += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: s, options: [.ignoreUnknownCharacters])
    }

    static func hexData(from hex: String) -> Data? {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: " ", with: "")
        if cleaned.hasPrefix("0x") || cleaned.hasPrefix("0X") {
            cleaned = String(cleaned.dropFirst(2))
        }
        guard cleaned.count % 2 == 0 else { return nil }
        var data = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    static func encoding(from name: String?) -> String.Encoding? {
        guard let name = name?.lowercased() else { return nil }
        switch name {
        case "utf-8", "utf8": return .utf8
        case "gbk", "gb2312", "gb18030":
            let cf = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
            return String.Encoding(rawValue: cf)
        case "iso-8859-1", "latin1": return .isoLatin1
        default: return nil
        }
    }

    static func gbkPercentEncode(_ str: String) -> String {
        guard let encoding = encoding(from: "gbk"),
              let data = str.data(using: encoding) else {
            return str
        }
        var result = ""
        for byte in data {
            let char = Character(UnicodeScalar(byte))
            if char.isLetter && byte < 128 || char.isNumber && byte < 128
                || "-_.~".contains(char) {
                result.append(char)
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    static func digestHex(_ input: String, algorithm: String) -> String? {
        guard let data = input.data(using: .utf8) else { return nil }
        let algo = algorithm.uppercased().replacingOccurrences(of: "-", with: "")
        switch algo {
        case "MD5":
            return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "SHA1":
            return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "SHA256":
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        case "SHA512":
            return SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        default:
            return nil
        }
    }
}

/// 书源自定义变量存储。
public final class VariableStore: @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init(initial: [String: String] = [:]) {
        self.storage = initial
    }

    public func get(_ key: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return storage[key] ?? ""
    }

    public func put(_ key: String, _ value: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }

    public var all: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// 简单的键值缓存，带 TTL。
public final class CacheManager: @unchecked Sendable {
    public static let shared = CacheManager()

    private struct Entry {
        let value: String
        let expireAt: Date?
    }

    private var storage: [String: Entry] = [:]
    private let lock = NSLock()

    public func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = storage[key] else { return nil }
        if let expireAt = entry.expireAt, expireAt < Date() {
            storage.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    public func put(_ key: String, value: String, ttlSeconds: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        let expireAt = ttlSeconds > 0
            ? Date().addingTimeInterval(TimeInterval(ttlSeconds)) : nil
        storage[key] = Entry(value: value, expireAt: expireAt)
    }

    public func remove(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}

/// JS 日志收集，供书源调试界面展示
public final class JSLog: @unchecked Sendable {
    public static let shared = JSLog()

    private var lines: [String] = []
    private let lock = NSLock()
    private let maxLines = 500

    public func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    public var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        lines.removeAll()
    }
}
