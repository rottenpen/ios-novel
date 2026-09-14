// Swift 实现及修改：Yuedu 项目，2026-09-14。
// 来源与许可见仓库根目录 THIRD_PARTY_NOTICES.md（GPL-3.0）。
import Foundation

/// HTML 文本格式化。
///
/// 格式化顺序（前后步骤存在依赖）：
/// nbsp → ensp/emsp → 不可打印字符 → 换行标签 → 注释 → 其余标签 → 缩进规整。
public enum TextFormatter {

    // 预编译正则，避免每章正文重复编译
    private static let nbspRegex = regex("(&nbsp;)+")
    private static let espRegex = regex("(&ensp;|&emsp;)")
    private static let noPrintRegex = regex("(&thinsp;|&zwnj;|&zwj;|\u{2009}|\u{200C}|\u{200D})")
    private static let wrapHtmlRegex = regex("</?(?:div|p|br|hr|h\\d|article|dd|dl)[^>]*>")
    private static let commentRegex = regex("<!--[^>]*-->")
    private static let notImgHtmlRegex = regex("</?(?!img)[a-zA-Z]+(?=[ >])[^<>]*>")
    private static let otherHtmlRegex = regex("</?[a-zA-Z]+(?=[ >])[^<>]*>")
    private static let indent1Regex = regex("\\s*\\n+\\s*")
    private static let indent2Regex = regex("^[\\n\\s]+")
    private static let lastRegex = "[\\n\\s]+$"

    /// `<img>` 提取，三个分支分别对应 {js} 参数型 src、data-* 懒加载、普通 src
    private static let formatImagePattern = regex(
        "<img[^>]*\\ssrc\\s*=\\s*\"([^\"{>]*\\{(?:[^{}]|\\{[^}>]+\\})+\\})\"[^>]*>"
            + "|<img[^>]*\\sdata-[^=>]*=\\s*\"([^\">]*)\"[^>]*>"
            + "|<img[^>]*\\ssrc\\s*=\\s*\"([^\">]*)\"[^>]*>",
        options: [.caseInsensitive]
    )

    /// AnalyzeUrl 的 `,{...}` 参数分隔。
    static let paramPattern = regex("\\s*,\\s*(?=\\{)")

    private static func regex(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        // 这些模式为编译期常量，构造失败属于开发期错误
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            preconditionFailure("Invalid built-in regex: \(pattern)")
        }
        return regex
    }

    private static func replaceAll(
        _ input: String,
        _ regex: NSRegularExpression,
        _ template: String
    ) -> String {
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(
            in: input, range: range, withTemplate: template
        )
    }

    /// 去除 HTML 标签得到纯文本，对应 `HtmlFormatter.format`
    public static func format(_ html: String?) -> String {
        format(html, otherRegex: otherHtmlRegex)
    }

    private static func format(_ html: String?, otherRegex: NSRegularExpression) -> String {
        guard let html, !html.isEmpty else { return "" }
        var result = replaceAll(html, nbspRegex, " ")
        result = replaceAll(result, espRegex, " ")
        result = replaceAll(result, noPrintRegex, "")
        result = replaceAll(result, wrapHtmlRegex, "\n")
        result = replaceAll(result, commentRegex, "")
        result = replaceAll(result, otherRegex, "")
        // 缩进：中文全角双空格
        result = replaceAll(result, indent1Regex, "\n　　")
        result = replaceAll(result, indent2Regex, "　　")
        if let trailing = try? NSRegularExpression(pattern: lastRegex) {
            result = replaceAll(result, trailing, "")
        }
        return result
    }

    /// JS 侧 `java.htmlFormat`
    public static func formatHTML(_ html: String) -> String {
        format(html)
    }

    /// 保留 `<img>` 标签并将其 src 转为绝对地址，对应 `HtmlFormatter.formatKeepImg`
    public static func formatKeepImg(_ html: String?, redirectUrl: String? = nil) -> String {
        guard let html, !html.isEmpty else { return "" }
        let keepImgHtml = format(html, otherRegex: notImgHtmlRegex)

        let nsHtml = keepImgHtml as NSString
        let matches = formatImagePattern.matches(
            in: keepImgHtml, range: NSRange(location: 0, length: nsHtml.length)
        )
        guard !matches.isEmpty else { return keepImgHtml }

        var sb = ""
        var appendPos = 0
        for match in matches {
            sb += nsHtml.substring(with: NSRange(location: appendPos, length: match.range.location - appendPos))

            // group1（含 {} 参数）优先，其次 data-*，最后普通 src
            var param = ""
            var rawSrc = ""
            if match.range(at: 1).location != NSNotFound {
                var src = nsHtml.substring(with: match.range(at: 1))
                // 拆出 `,{...}` 选项部分，仅对 URL 主体做绝对化
                let srcNS = src as NSString
                if let m = paramPattern.firstMatch(
                    in: src, range: NSRange(location: 0, length: srcNS.length)
                ) {
                    param = "," + srcNS.substring(from: m.range.location + m.range.length)
                    src = srcNS.substring(to: m.range.location)
                }
                rawSrc = src
            } else if match.range(at: 2).location != NSNotFound {
                rawSrc = nsHtml.substring(with: match.range(at: 2))
            } else if match.range(at: 3).location != NSNotFound {
                rawSrc = nsHtml.substring(with: match.range(at: 3))
            }

            let absolute = NetworkUtils.absoluteURL(base: redirectUrl ?? "", relative: rawSrc)
            sb += "<img src=\"\(absolute)\(param)\">"
            appendPos = match.range.location + match.range.length
        }
        if appendPos < nsHtml.length {
            sb += nsHtml.substring(from: appendPos)
        }
        return sb
    }

    /// 中文数字章节名转阿拉伯数字，对应 JS 侧 `java.toNumChapter`
    public static func chineseNumbersToArabic(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "第([零一二三四五六七八九十百千万〇两]+)([章节回卷集话篇部])"
        ) else { return text }

        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var pos = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: pos, length: match.range.location - pos))
            let chinese = ns.substring(with: match.range(at: 1))
            let suffix = ns.substring(with: match.range(at: 2))
            if let value = chineseToInt(chinese) {
                result += "第\(value)\(suffix)"
            } else {
                result += ns.substring(with: match.range)
            }
            pos = match.range.location + match.range.length
        }
        if pos < ns.length {
            result += ns.substring(from: pos)
        }
        return result
    }

    /// 中文数字串转整数，支持「十」「百」「千」「万」进位与「〇/两」别写
    static func chineseToInt(_ text: String) -> Int? {
        let digits: [Character: Int] = [
            "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000]

        var total = 0
        var section = 0
        var current = 0
        var sawAny = false

        for ch in text {
            if let digit = digits[ch] {
                current = digit
                sawAny = true
            } else if let unit = units[ch] {
                // 「十三」这类省略前导 1 的写法
                section += (current == 0 ? 1 : current) * unit
                current = 0
                sawAny = true
            } else if ch == "万" {
                total += (section + current) * 10000
                section = 0
                current = 0
                sawAny = true
            } else {
                return nil
            }
        }
        guard sawAny else { return nil }
        return total + section + current
    }

    /// 字数格式化。
    public static func wordCountFormat(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        // 已带单位的原样返回
        if text.contains("万") || text.contains("字") || text.contains("k") || text.contains("K") {
            return text
        }
        guard let count = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return text
        }
        if count < 1000 { return "\(count)字" }
        if count < 10000 {
            return String(format: "%.1fK字", Double(count) / 1000)
        }
        return String(format: "%.1f万字", Double(count) / 10000)
    }

    /// 书名规整，对应 `BookHelp.formatBookName`
    public static func formatBookName(_ name: String) -> String {
        name.replacingOccurrences(
            of: "^\\s*《?|》?\\s*$",
            with: "",
            options: .regularExpression
        )
    }

    /// 作者名规整，去掉「作者：」等前缀，对应 `BookHelp.formatBookAuthor`
    public static func formatBookAuthor(_ author: String) -> String {
        author.replacingOccurrences(
            of: "^\\s*(作\\s*者\\s*[:：]?)|(\\s*著\\s*)$",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// HTML 实体反转义。
    /// Foundation 无内置实现，这里覆盖正文场景高频实体 + 数字实体。
    public static func unescapeHTML(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named: [String: String] = [
            "&lt;": "<", "&gt;": ">", "&amp;": "&", "&quot;": "\"", "&apos;": "'",
            "&nbsp;": " ", "&ensp;": " ", "&emsp;": " ", "&thinsp;": "",
            "&middot;": "·", "&hellip;": "…", "&mdash;": "—", "&ndash;": "–",
            "&ldquo;": "“", "&rdquo;": "”", "&lsquo;": "‘", "&rsquo;": "’",
            "&laquo;": "«", "&raquo;": "»", "&copy;": "©", "&reg;": "®",
            "&trade;": "™", "&deg;": "°", "&plusmn;": "±", "&times;": "×",
            "&divide;": "÷", "&frac12;": "½", "&sup2;": "²", "&sup3;": "³",
            "&bull;": "•", "&dagger;": "†", "&permil;": "‰", "&euro;": "€",
            "&pound;": "£", "&yen;": "¥", "&cent;": "¢", "&sect;": "§",
            "&para;": "¶", "&micro;": "µ", "&para": "¶"
        ]
        for (entity, char) in named {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        // 数字实体 &#123; / &#x1F600;
        result = replaceNumericEntities(result)
        // &amp; 需最后处理，避免二次解码
        return result
    }

    private static func replaceNumericEntities(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "&#([xX]?)([0-9a-fA-F]+);") else {
            return text
        }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = ""
        var pos = 0
        for match in matches {
            result += ns.substring(with: NSRange(location: pos, length: match.range.location - pos))
            let isHex = !ns.substring(with: match.range(at: 1)).isEmpty
            let digits = ns.substring(with: match.range(at: 2))
            if let code = UInt32(digits, radix: isHex ? 16 : 10),
               let scalar = UnicodeScalar(code) {
                result.append(Character(scalar))
            } else {
                result += ns.substring(with: match.range)
            }
            pos = match.range.location + match.range.length
        }
        if pos < ns.length {
            result += ns.substring(from: pos)
        }
        return result
    }

    /// 判断字符串是否为「真」。
    public static func isTrue(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "null", "false", "0", "no", "not", "错误": return false
        default: return true
        }
    }
}
