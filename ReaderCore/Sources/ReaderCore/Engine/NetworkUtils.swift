// Swift 实现及修改：Yuedu 项目，2026-09-14。
// 来源与许可见仓库根目录 THIRD_PARTY_NOTICES.md（GPL-3.0）。
import Foundation

/// URL 处理工具。
public enum NetworkUtils {

    /// 相对地址转绝对地址，对应 `NetworkUtils.getAbsoluteURL`。
    ///
    /// 地址解析约定：
    /// - relative 为空时返回 base
    /// - relative 已是绝对地址（含 scheme）时原样返回
    /// - `//host/path` 协议相对地址继承 base 的 scheme
    /// - base 不合法时退化为返回 relative，不抛异常（书源质量参差，必须容错）
    public static func absoluteURL(base: String?, relative: String) -> String {
        let relativeTrimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base, !base.isEmpty else { return relativeTrimmed }
        if relativeTrimmed.isEmpty { return base }

        // data: / javascript: / 已带 scheme 的绝对地址
        if relativeTrimmed.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) != nil {
            return relativeTrimmed
        }

        // 协议相对地址
        if relativeTrimmed.hasPrefix("//") {
            let scheme = base.hasPrefix("https") ? "https" : "http"
            return "\(scheme):\(relativeTrimmed)"
        }

        guard let baseURL = URL(string: base) else { return relativeTrimmed }
        guard let resolved = URL(string: relativeTrimmed, relativeTo: baseURL) else {
            return relativeTrimmed
        }
        return resolved.absoluteString
    }

    /// 取 `scheme://host` 形式的基础地址，对应 `NetworkUtils.getBaseUrl`
    public static func baseURL(of url: String) -> String? {
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme,
              let host = parsed.host else {
            return nil
        }
        if let port = parsed.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    /// 取主域名（去掉子域），对应 `NetworkUtils.getSubDomain`。
    /// 用于并发限流与 Cookie 归组，无需完整 PSL，取末两段即可满足书源场景。
    public static func subDomain(of url: String) -> String {
        guard let host = URL(string: url)?.host ?? URL(string: "http://\(url)")?.host else {
            return url
        }
        let parts = host.split(separator: ".")
        guard parts.count > 2 else { return host }
        // 处理 com.cn / co.jp 这类二级后缀
        let secondLevel = ["com", "net", "org", "gov", "edu", "co"]
        if parts.count >= 3, secondLevel.contains(String(parts[parts.count - 2])) {
            return parts.suffix(3).joined(separator: ".")
        }
        return parts.suffix(2).joined(separator: ".")
    }

    /// 判断字符串是否已经过 URL 编码，对应 `NetworkUtils.hasUrlEncoded`
    public static func hasURLEncoded(_ text: String) -> Bool {
        var needEncode = false
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == "%" {
                // %XX 形式视为已编码
                let next = text.index(after: index)
                if next < text.endIndex,
                   let after = text.index(next, offsetBy: 1, limitedBy: text.endIndex),
                   after < text.endIndex || next < text.endIndex {
                    let hexEnd = text.index(next, offsetBy: 2, limitedBy: text.endIndex) ?? text.endIndex
                    let hex = text[next..<hexEnd]
                    if hex.count == 2, hex.allSatisfy({ $0.isHexDigit }) {
                        return true
                    }
                }
                needEncode = true
            }
            index = text.index(after: index)
        }
        return needEncode
    }

    /// 从 Content-Type 或 HTML meta 中探测字符集
    public static func detectCharset(contentType: String?, data: Data) -> String.Encoding {
        // 1) HTTP 头优先
        if let contentType,
           let range = contentType.range(of: "charset=", options: .caseInsensitive) {
            let raw = contentType[range.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " \";'"))
            if let encoding = JSEngine.encoding(from: raw) {
                return encoding
            }
        }

        // 2) HTML meta charset：只在头部 1KB 内嗅探，避免整篇解码开销
        let head = data.prefix(1024)
        if let headText = String(data: head, encoding: .isoLatin1) {
            let patterns = [
                "charset=[\"']?([a-zA-Z0-9_-]+)",
                "encoding=[\"']?([a-zA-Z0-9_-]+)"
            ]
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                    let ns = headText as NSString
                    if let match = regex.firstMatch(
                        in: headText, range: NSRange(location: 0, length: ns.length)
                    ), match.numberOfRanges > 1 {
                        let name = ns.substring(with: match.range(at: 1))
                        if let encoding = JSEngine.encoding(from: name) {
                            return encoding
                        }
                    }
                }
            }
        }

        // 3) 兜底：能按 UTF-8 解码则 UTF-8，否则按 GBK（中文站点常见）
        if String(data: data, encoding: .utf8) != nil { return .utf8 }
        return JSEngine.encoding(from: "gbk") ?? .utf8
    }

    /// 按探测到的字符集解码响应体
    public static func decode(data: Data, contentType: String?, forcedCharset: String?) -> String? {
        if let forcedCharset, let encoding = JSEngine.encoding(from: forcedCharset) {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        let encoding = detectCharset(contentType: contentType, data: data)
        if let text = String(data: data, encoding: encoding) { return text }
        // 逐个兜底，避免因单一编码失败而丢内容
        for fallback: String.Encoding in [.utf8, .isoLatin1] {
            if let text = String(data: data, encoding: fallback) { return text }
        }
        return nil
    }

    /// 判断文本是否为 JSON。
    public static func isJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else { return false }
        return (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
    }

    /// 判断文本是否为 XML
    public static func isXML(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<?xml")
    }
}
