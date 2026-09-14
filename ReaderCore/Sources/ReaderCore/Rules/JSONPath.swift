// Swift 实现及修改：Yuedu 项目，2026-09-14。
// 来源与许可见仓库根目录 THIRD_PARTY_NOTICES.md（GPL-3.0）。
import Foundation

/// JSONPath 求值器。
///
/// 支持书源常用的 JSONPath 语法：
/// - `$.a.b.c` 属性访问
/// - `$['a']['b']` / `$["a"]` 括号属性访问（含含特殊字符的键）
/// - `$.a[0]` / `$.a[-1]` 数组索引（支持负数）
/// - `$.a[0,2]` 多索引
/// - `$.a[1:3]` / `$.a[:2]` / `$.a[2:]` 切片
/// - `$.a[*]` 通配
/// - `$..name` 递归下降
/// - `$.a[?(@.b == 'x')]` 过滤表达式（支持 == != > < >= <= 与 && ||，以及 `@.k` 存在性判断）
/// - `$.a.length()` 长度函数
///
/// 有意不支持的（书源中极少出现，且易引入歧义）：脚本表达式 `[(...)]`、正则匹配过滤 `=~`。
/// 遇到不支持的语法返回 nil，由上层规则降级处理，而不是抛错中断整条书源。
public enum JSONPath {

    // MARK: - Public

    /// 求值并返回原始 JSON 值（Any：字典/数组/字符串/数字/布尔）
    public static func read(_ json: Any, path: String) -> Any? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var normalized = trimmed
        if normalized.hasPrefix("$") {
            normalized = String(normalized.dropFirst())
        }

        guard let tokens = tokenize(normalized) else { return nil }

        var current: [Any] = [json]
        var isDefinite = true  // 是否为确定性单值路径

        for token in tokens {
            var next: [Any] = []
            switch token {
            case let .property(name):
                for node in current {
                    if let dict = node as? [String: Any], let value = dict[name] {
                        next.append(value)
                    }
                }

            case let .index(indices):
                if indices.count > 1 { isDefinite = false }
                for node in current {
                    guard let array = node as? [Any] else { continue }
                    for raw in indices {
                        let idx = raw < 0 ? array.count + raw : raw
                        if idx >= 0 && idx < array.count {
                            next.append(array[idx])
                        }
                    }
                }

            case let .slice(start, end, step):
                isDefinite = false
                for node in current {
                    guard let array = node as? [Any] else { continue }
                    let count = array.count
                    var s = start ?? 0
                    var e = end ?? count
                    if s < 0 { s = max(0, count + s) }
                    if e < 0 { e = max(0, count + e) }
                    s = min(max(0, s), count)
                    e = min(max(0, e), count)
                    let st = max(1, step ?? 1)
                    if s < e {
                        var i = s
                        while i < e {
                            next.append(array[i])
                            i += st
                        }
                    }
                }

            case .wildcard:
                isDefinite = false
                for node in current {
                    if let array = node as? [Any] {
                        next.append(contentsOf: array)
                    } else if let dict = node as? [String: Any] {
                        next.append(contentsOf: dict.values)
                    }
                }

            case let .recursive(name):
                isDefinite = false
                for node in current {
                    collectRecursive(node, key: name, into: &next)
                }

            case let .filter(expr):
                isDefinite = false
                for node in current {
                    if let array = node as? [Any] {
                        for item in array where evaluateFilter(expr, on: item) {
                            next.append(item)
                        }
                    } else if let dict = node as? [String: Any] {
                        if evaluateFilter(expr, on: dict) { next.append(dict) }
                    }
                }

            case .length:
                for node in current {
                    if let array = node as? [Any] {
                        next.append(array.count)
                    } else if let dict = node as? [String: Any] {
                        next.append(dict.count)
                    } else if let str = node as? String {
                        next.append(str.count)
                    }
                }
            }
            current = next
            if current.isEmpty { return nil }
        }

        if isDefinite && current.count == 1 {
            return current[0]
        }
        return current.count == 1 && isDefinite ? current[0] : current
    }

    /// 求值并转成书源规则使用的字符串（列表以换行连接）
    public static func string(_ json: Any, path: String) -> String? {
        guard let value = read(json, path: path) else { return nil }
        if let list = value as? [Any] {
            if list.isEmpty { return nil }
            return list.map { stringify($0) }.joined(separator: "\n")
        }
        return stringify(value)
    }

    /// 求值并返回字符串列表
    public static func stringList(_ json: Any, path: String) -> [String] {
        guard let value = read(json, path: path) else { return [] }
        if let list = value as? [Any] {
            return list.map { stringify($0) }
        }
        return [stringify(value)]
    }

    /// 求值并返回节点列表（用于 bookList 之类的列表规则）
    public static func nodeList(_ json: Any, path: String) -> [Any] {
        guard let value = read(json, path: path) else { return [] }
        if let list = value as? [Any] { return list }
        return [value]
    }

    /// 数字转字符串时去掉无意义的 `.0`
    public static func stringify(_ value: Any) -> String {
        switch value {
        case let str as String:
            return str
        case let num as Int:
            return String(num)
        case let num as Double:
            if num.truncatingRemainder(dividingBy: 1) == 0 && abs(num) < 1e15 {
                return String(format: "%.0f", num)
            }
            return String(num)
        case let num as NSNumber:
            let d = num.doubleValue
            if d.truncatingRemainder(dividingBy: 1) == 0 && abs(d) < 1e15 {
                return String(format: "%.0f", d)
            }
            return num.stringValue
        case let flag as Bool:
            return flag ? "true" : "false"
        case is NSNull:
            return ""
        default:
            if let data = try? JSONSerialization.data(withJSONObject: value),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return String(describing: value)
        }
    }

    /// 解析 JSON 文本
    public static func parse(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        )
    }

    // MARK: - Tokenizer

    private enum Token {
        case property(String)
        case index([Int])
        case slice(start: Int?, end: Int?, step: Int?)
        case wildcard
        case recursive(String)
        case filter(String)
        case length
    }

    private static func tokenize(_ path: String) -> [Token]? {
        var tokens: [Token] = []
        let chars = Array(path)
        var i = 0

        while i < chars.count {
            let c = chars[i]

            if c == "." {
                // 递归下降 ..name
                if i + 1 < chars.count && chars[i + 1] == "." {
                    i += 2
                    var name = ""
                    while i < chars.count, chars[i] != ".", chars[i] != "[" {
                        name.append(chars[i])
                        i += 1
                    }
                    if name == "*" {
                        tokens.append(.recursive(""))
                    } else if !name.isEmpty {
                        tokens.append(.recursive(name))
                    }
                    continue
                }
                i += 1
                var name = ""
                while i < chars.count, chars[i] != ".", chars[i] != "[" {
                    name.append(chars[i])
                    i += 1
                }
                if name == "*" {
                    tokens.append(.wildcard)
                } else if name == "length()" {
                    tokens.append(.length)
                } else if !name.isEmpty {
                    tokens.append(.property(name))
                }
                continue
            }

            if c == "[" {
                // 找到匹配的 ]，考虑引号与嵌套括号
                var depth = 0
                var j = i
                var inSingle = false
                var inDouble = false
                var body = ""
                while j < chars.count {
                    let ch = chars[j]
                    if ch == "'" && !inDouble { inSingle.toggle() }
                    if ch == "\"" && !inSingle { inDouble.toggle() }
                    if !inSingle && !inDouble {
                        if ch == "[" { depth += 1 }
                        if ch == "]" {
                            depth -= 1
                            if depth == 0 { break }
                        }
                    }
                    if depth >= 1 && !(j == i) { body.append(ch) }
                    j += 1
                }
                if depth != 0 { return nil }
                i = j + 1

                let inner = body.trimmingCharacters(in: .whitespaces)
                if inner == "*" {
                    tokens.append(.wildcard)
                } else if inner.hasPrefix("?") {
                    // 过滤表达式 ?(...)
                    var expr = String(inner.dropFirst())
                    if expr.hasPrefix("(") && expr.hasSuffix(")") {
                        expr = String(expr.dropFirst().dropLast())
                    }
                    tokens.append(.filter(expr))
                } else if inner.hasPrefix("'") || inner.hasPrefix("\"") {
                    // 括号属性访问，可能是多个 ['a','b']
                    let names = splitTopLevel(inner, by: ",")
                        .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                    if names.count == 1 {
                        tokens.append(.property(names[0]))
                    } else {
                        // 多属性访问较少见，按顺序展开为递归取值
                        for name in names { tokens.append(.property(name)) }
                    }
                } else if inner.contains(":") {
                    let parts = inner.components(separatedBy: ":")
                    let start = Int(parts[0].trimmingCharacters(in: .whitespaces))
                    let end = parts.count > 1
                        ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
                    let step = parts.count > 2
                        ? Int(parts[2].trimmingCharacters(in: .whitespaces)) : nil
                    tokens.append(.slice(start: start, end: end, step: step))
                } else if inner.contains(",") {
                    let indices = inner.components(separatedBy: ",")
                        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    if indices.isEmpty { return nil }
                    tokens.append(.index(indices))
                } else if let idx = Int(inner) {
                    tokens.append(.index([idx]))
                } else if !inner.isEmpty {
                    // 无引号的属性名
                    tokens.append(.property(inner))
                }
                continue
            }

            // 起始处直接跟属性名（如 "name"）
            var name = ""
            while i < chars.count, chars[i] != ".", chars[i] != "[" {
                name.append(chars[i])
                i += 1
            }
            if !name.isEmpty {
                if name == "length()" {
                    tokens.append(.length)
                } else {
                    tokens.append(.property(name))
                }
            }
        }
        return tokens
    }

    private static func unquote(_ str: String) -> String {
        var s = str
        if (s.hasPrefix("'") && s.hasSuffix("'")) || (s.hasPrefix("\"") && s.hasSuffix("\"")) {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    /// 按分隔符切分，但忽略引号与括号内部的分隔符
    private static func splitTopLevel(_ str: String, by sep: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var depth = 0
        for ch in str {
            if ch == "'" && !inDouble { inSingle.toggle() }
            if ch == "\"" && !inSingle { inDouble.toggle() }
            if !inSingle && !inDouble {
                if ch == "(" || ch == "[" { depth += 1 }
                if ch == ")" || ch == "]" { depth -= 1 }
                if ch == sep && depth == 0 {
                    result.append(current)
                    current = ""
                    continue
                }
            }
            current.append(ch)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func collectRecursive(_ node: Any, key: String, into result: inout [Any]) {
        if let dict = node as? [String: Any] {
            if key.isEmpty {
                result.append(contentsOf: dict.values)
            } else if let value = dict[key] {
                result.append(value)
            }
            for value in dict.values {
                collectRecursive(value, key: key, into: &result)
            }
        } else if let array = node as? [Any] {
            for item in array {
                collectRecursive(item, key: key, into: &result)
            }
        }
    }

    // MARK: - Filter evaluation

    /// 求值过滤表达式，支持 `&&` / `||` 与常见比较运算
    private static func evaluateFilter(_ expr: String, on node: Any) -> Bool {
        let trimmed = expr.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }

        // 先处理 ||（优先级最低）
        let orParts = splitLogical(trimmed, op: "||")
        if orParts.count > 1 {
            return orParts.contains { evaluateFilter($0, on: node) }
        }
        let andParts = splitLogical(trimmed, op: "&&")
        if andParts.count > 1 {
            return andParts.allSatisfy { evaluateFilter($0, on: node) }
        }

        var body = trimmed
        // 去掉最外层括号
        while body.hasPrefix("(") && body.hasSuffix(")") {
            let inner = String(body.dropFirst().dropLast())
            if splitLogical(inner, op: "||").count > 1 || splitLogical(inner, op: "&&").count > 1 {
                return evaluateFilter(inner, on: node)
            }
            body = inner.trimmingCharacters(in: .whitespaces)
        }

        // 比较运算
        let operators = ["==", "!=", ">=", "<=", ">", "<"]
        for op in operators {
            if let range = rangeOfTopLevel(body, op) {
                let lhsRaw = String(body[body.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let rhsRaw = String(body[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                let lhs = resolveOperand(lhsRaw, on: node)
                let rhs = resolveOperand(rhsRaw, on: node)
                return compare(lhs, rhs, op: op)
            }
        }

        // 无运算符：存在性判断 @.key
        let value = resolveOperand(body, on: node)
        if value == nil { return false }
        if let flag = value as? Bool { return flag }
        if value is NSNull { return false }
        return true
    }

    private static func splitLogical(_ str: String, op: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var depth = 0
        let chars = Array(str)
        let opChars = Array(op)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "'" && !inDouble { inSingle.toggle() }
            if ch == "\"" && !inSingle { inDouble.toggle() }
            if !inSingle && !inDouble {
                if ch == "(" || ch == "[" { depth += 1 }
                if ch == ")" || ch == "]" { depth -= 1 }
                if depth == 0, i + opChars.count <= chars.count {
                    var matched = true
                    for j in 0..<opChars.count where chars[i + j] != opChars[j] {
                        matched = false
                        break
                    }
                    if matched {
                        result.append(current)
                        current = ""
                        i += opChars.count
                        continue
                    }
                }
            }
            current.append(ch)
            i += 1
        }
        if !current.isEmpty { result.append(current) }
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func rangeOfTopLevel(_ str: String, _ op: String) -> Range<String.Index>? {
        var inSingle = false
        var inDouble = false
        var depth = 0
        var idx = str.startIndex
        let opCount = op.count
        while idx < str.endIndex {
            let ch = str[idx]
            if ch == "'" && !inDouble { inSingle.toggle() }
            if ch == "\"" && !inSingle { inDouble.toggle() }
            if !inSingle && !inDouble {
                if ch == "(" || ch == "[" { depth += 1 }
                if ch == ")" || ch == "]" { depth -= 1 }
                if depth == 0 {
                    if let end = str.index(idx, offsetBy: opCount, limitedBy: str.endIndex),
                       String(str[idx..<end]) == op {
                        // 避免把 >= 误判成 >
                        if op == ">" || op == "<" {
                            if end < str.endIndex && str[end] == "=" {
                                idx = str.index(after: idx)
                                continue
                            }
                        }
                        return idx..<end
                    }
                }
            }
            idx = str.index(after: idx)
        }
        return nil
    }

    private static func resolveOperand(_ raw: String, on node: Any) -> Any? {
        let token = raw.trimmingCharacters(in: .whitespaces)
        if token.hasPrefix("@") {
            var sub = String(token.dropFirst())
            if sub.hasPrefix(".") { sub = String(sub.dropFirst()) }
            if sub.isEmpty { return node }
            // 支持 @.a.b 与 @['a']
            return read(node, path: sub.hasPrefix("[") ? sub : "." + sub)
        }
        if (token.hasPrefix("'") && token.hasSuffix("'"))
            || (token.hasPrefix("\"") && token.hasSuffix("\"")) {
            return unquote(token)
        }
        if let intValue = Int(token) { return intValue }
        if let doubleValue = Double(token) { return doubleValue }
        if token == "true" { return true }
        if token == "false" { return false }
        if token == "null" { return NSNull() }
        return token
    }

    private static func compare(_ lhs: Any?, _ rhs: Any?, op: String) -> Bool {
        // nil 处理
        if lhs == nil || lhs is NSNull {
            if op == "==" { return rhs == nil || rhs is NSNull }
            if op == "!=" { return !(rhs == nil || rhs is NSNull) }
            return false
        }

        if let l = numeric(lhs), let r = numeric(rhs) {
            switch op {
            case "==": return l == r
            case "!=": return l != r
            case ">": return l > r
            case "<": return l < r
            case ">=": return l >= r
            case "<=": return l <= r
            default: return false
            }
        }

        let l = stringify(lhs!)
        let r = rhs == nil ? "" : stringify(rhs!)
        switch op {
        case "==": return l == r
        case "!=": return l != r
        case ">": return l > r
        case "<": return l < r
        case ">=": return l >= r
        case "<=": return l <= r
        default: return false
        }
    }

    private static func numeric(_ value: Any?) -> Double? {
        switch value {
        case let v as Int: return Double(v)
        case let v as Double: return v
        case let v as NSNumber: return v.doubleValue
        case let v as String: return Double(v)
        default: return nil
        }
    }
}
