// Swift 实现及修改：Yuedu 项目，2026-09-14。
// 来源与许可见仓库根目录 THIRD_PARTY_NOTICES.md（GPL-3.0）。
import Foundation
import SwiftSoup

/// XPath 规则解析。
///
/// iOS 平台无 JsoupXpath 等价库，这里在 SwiftSoup 之上实现书源实际使用的 XPath 子集：
/// - `//div`、`/html/body/div` 路径定位（`//` 后代、`/` 直接子级）
/// - `//div[@class="x"]`、`[@id='y']`、`[@href]` 属性谓词
/// - `//div[contains(@class,'x')]`、`[starts-with(@href,'/b')]` 函数谓词
/// - `//div[1]`、`[last()]`、`[position()<3]` 位置谓词
/// - `//div[text()='x']`、`[contains(text(),'x')]` 文本谓词
/// - 末端取值：`/text()`、`/@href`、`/html()`、`/allText()`、`/tidyText()`
/// - `|` 并集
///
/// 不支持轴（`ancestor::`、`following-sibling::` 等）与复杂函数嵌套；遇到不支持的
/// 语法返回空结果，由上层降级，而不是中断整条书源解析。
public final class AnalyzeByXPath {
    private let root: Element

    public init(doc: Any) throws {
        if let element = doc as? Element {
            self.root = element
        } else {
            let text = String(describing: doc)
            if text.lowercased().hasPrefix("<?xml") {
                self.root = try SwiftSoup.parse(text, "", Parser.xmlParser())
            } else {
                self.root = try SwiftSoup.parse(text)
            }
        }
    }

    // MARK: - Public API

    public func getElements(_ xpath: String) -> [Element] {
        let unions = splitUnion(xpath)
        var result: [Element] = []
        for path in unions {
            let (elements, _) = evaluate(path)
            for el in elements where !result.contains(where: { $0 === el }) {
                result.append(el)
            }
        }
        return result
    }

    public func getStringList(_ xpath: String) -> [String] {
        let unions = splitUnion(xpath)
        var result: [String] = []
        for path in unions {
            let (elements, terminal) = evaluate(path)
            result.append(contentsOf: extract(elements, terminal: terminal))
        }
        return result
    }

    public func getString(_ xpath: String) -> String? {
        let list = getStringList(xpath)
        if list.isEmpty { return nil }
        if list.count == 1 { return list[0] }
        return list.joined(separator: "\n")
    }

    public func getString0(_ xpath: String) -> String {
        getStringList(xpath).first ?? ""
    }

    // MARK: - Terminal value

    private enum Terminal {
        case none
        case text
        case allText
        case tidyText
        case html
        case attr(String)
    }

    private func extract(_ elements: [Element], terminal: Terminal) -> [String] {
        var result: [String] = []
        for el in elements {
            switch terminal {
            case .none:
                if let html = try? el.outerHtml(), !html.isEmpty { result.append(html) }
            case .text:
                // XPath text() 语义：直属文本节点
                let tn = el.textNodes()
                    .map { $0.text().trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !tn.isEmpty {
                    result.append(contentsOf: tn)
                } else if let t = try? el.text(), !t.isEmpty {
                    result.append(t)
                }
            case .allText:
                if let t = try? el.text(), !t.isEmpty { result.append(t) }
            case .tidyText:
                if let t = try? el.text() {
                    let tidy = t.replacingOccurrences(
                        of: "\\s+", with: " ", options: .regularExpression
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !tidy.isEmpty { result.append(tidy) }
                }
            case .html:
                if let h = try? el.html(), !h.isEmpty { result.append(h) }
            case let .attr(name):
                if let v = try? el.attr(name), !v.isEmpty { result.append(v) }
            }
        }
        return result
    }

    // MARK: - Evaluation

    private func evaluate(_ xpath: String) -> ([Element], Terminal) {
        var path = xpath.trimmingCharacters(in: .whitespacesAndNewlines)
        var terminal = Terminal.none

        // 解析末端取值函数
        let terminalPatterns: [(String, Terminal)] = [
            ("/text()", .text),
            ("/allText()", .allText),
            ("/tidyText()", .tidyText),
            ("/html()", .html)
        ]
        for (suffix, t) in terminalPatterns where path.hasSuffix(suffix) {
            path = String(path.dropLast(suffix.count))
            terminal = t
            break
        }
        // 属性取值 /@href
        if case .none = terminal {
            if let atRange = path.range(of: "/@", options: .backwards) {
                let attrName = String(path[atRange.upperBound...])
                if !attrName.isEmpty, !attrName.contains("/"), !attrName.contains("[") {
                    path = String(path[path.startIndex..<atRange.lowerBound])
                    terminal = .attr(attrName)
                }
            }
        }

        var current: [Element] = [root]
        var index = path.startIndex

        while index < path.endIndex {
            // 判断是 // (后代) 还是 / (直接子级)
            var descendant = false
            if path[index] == "/" {
                let next = path.index(after: index)
                if next < path.endIndex && path[next] == "/" {
                    descendant = true
                    index = path.index(after: next)
                } else {
                    index = next
                }
            } else if index == path.startIndex {
                // 相对路径按后代处理
                descendant = true
            }

            guard index < path.endIndex else { break }

            // 读取一个 step：名称 + 谓词
            var step = ""
            var depth = 0
            var inSingle = false
            var inDouble = false
            while index < path.endIndex {
                let ch = path[index]
                if ch == "'" && !inDouble { inSingle.toggle() }
                if ch == "\"" && !inSingle { inDouble.toggle() }
                if !inSingle && !inDouble {
                    if ch == "[" { depth += 1 }
                    if ch == "]" { depth -= 1 }
                    if ch == "/" && depth == 0 { break }
                }
                step.append(ch)
                index = path.index(after: index)
            }

            if step.isEmpty { continue }
            current = applyStep(step, to: current, descendant: descendant)
            if current.isEmpty { return ([], terminal) }
        }

        return (current, terminal)
    }

    private func applyStep(
        _ step: String,
        to nodes: [Element],
        descendant: Bool
    ) -> [Element] {
        // 拆分名称与谓词
        var name = ""
        var predicates: [String] = []
        var i = step.startIndex
        while i < step.endIndex, step[i] != "[" {
            name.append(step[i])
            i = step.index(after: i)
        }
        while i < step.endIndex, step[i] == "[" {
            var depth = 0
            var body = ""
            var inSingle = false
            var inDouble = false
            while i < step.endIndex {
                let ch = step[i]
                if ch == "'" && !inDouble { inSingle.toggle() }
                if ch == "\"" && !inSingle { inDouble.toggle() }
                if !inSingle && !inDouble {
                    if ch == "[" {
                        depth += 1
                        i = step.index(after: i)
                        if depth == 1 { continue }
                        body.append(ch)
                        continue
                    }
                    if ch == "]" {
                        depth -= 1
                        i = step.index(after: i)
                        if depth == 0 { break }
                        body.append(ch)
                        continue
                    }
                }
                body.append(ch)
                i = step.index(after: i)
            }
            predicates.append(body)
        }

        name = name.trimmingCharacters(in: .whitespaces)

        // 按名称选择
        var candidates: [Element] = []
        for node in nodes {
            let matched: [Element]
            if name == "*" {
                matched = descendant ? allDescendants(node) : node.children().array()
            } else if name == "." {
                matched = [node]
            } else if name.isEmpty {
                matched = []
            } else {
                if descendant {
                    matched = (try? node.getElementsByTag(name).array()) ?? []
                } else {
                    matched = node.children().array().filter { $0.tagName() == name }
                }
            }
            for el in matched where !candidates.contains(where: { $0 === el }) {
                candidates.append(el)
            }
        }

        // 应用谓词
        for predicate in predicates {
            candidates = applyPredicate(predicate, to: candidates)
        }
        return candidates
    }

    private func allDescendants(_ node: Element) -> [Element] {
        var result: [Element] = []
        for child in node.children().array() {
            result.append(child)
            result.append(contentsOf: allDescendants(child))
        }
        return result
    }

    private func applyPredicate(_ predicate: String, to nodes: [Element]) -> [Element] {
        let expr = predicate.trimmingCharacters(in: .whitespaces)
        if expr.isEmpty { return nodes }

        // 纯数字：位置索引（XPath 从 1 开始）
        if let pos = Int(expr) {
            let idx = pos - 1
            if idx >= 0 && idx < nodes.count { return [nodes[idx]] }
            return []
        }

        if expr == "last()" {
            return nodes.isEmpty ? [] : [nodes[nodes.count - 1]]
        }

        // position() 比较
        if expr.hasPrefix("position()") {
            let rest = String(expr.dropFirst("position()".count))
                .trimmingCharacters(in: .whitespaces)
            for op in [">=", "<=", "!=", "=", ">", "<"] where rest.hasPrefix(op) {
                let valStr = String(rest.dropFirst(op.count)).trimmingCharacters(in: .whitespaces)
                guard let val = Int(valStr) else { return nodes }
                return nodes.enumerated().filter { pair in
                    let pos = pair.offset + 1
                    switch op {
                    case "=": return pos == val
                    case "!=": return pos != val
                    case ">": return pos > val
                    case "<": return pos < val
                    case ">=": return pos >= val
                    case "<=": return pos <= val
                    default: return true
                    }
                }.map(\.element)
            }
        }

        // 逻辑组合
        if let parts = splitLogic(expr, op: " or "), parts.count > 1 {
            var result: [Element] = []
            for part in parts {
                for el in applyPredicate(part, to: nodes)
                where !result.contains(where: { $0 === el }) {
                    result.append(el)
                }
            }
            return result
        }
        if let parts = splitLogic(expr, op: " and "), parts.count > 1 {
            var result = nodes
            for part in parts {
                result = applyPredicate(part, to: result)
            }
            return result
        }

        // contains(@attr,'v') / contains(text(),'v')
        if expr.hasPrefix("contains(") {
            guard let inner = extractArgs(expr, prefix: "contains(") else { return nodes }
            return nodes.filter { el in
                let haystack = resolveValue(inner.0, on: el) ?? ""
                return haystack.contains(inner.1)
            }
        }

        // starts-with(@attr,'v')
        if expr.hasPrefix("starts-with(") {
            guard let inner = extractArgs(expr, prefix: "starts-with(") else { return nodes }
            return nodes.filter { el in
                (resolveValue(inner.0, on: el) ?? "").hasPrefix(inner.1)
            }
        }

        // 属性/文本比较或存在性
        for op in ["!=", "="] {
            if let range = expr.range(of: op) {
                let lhs = String(expr[expr.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                var rhs = String(expr[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                rhs = unquote(rhs)
                return nodes.filter { el in
                    let value = resolveValue(lhs, on: el)
                    if op == "=" {
                        return value == rhs
                    } else {
                        return value != rhs
                    }
                }
            }
        }

        // 存在性判断 [@href]
        if expr.hasPrefix("@") {
            let attr = String(expr.dropFirst())
            return nodes.filter { el in
                (try? el.attr(attr))?.isEmpty == false
            }
        }

        // 子元素存在判断 [div]
        return nodes.filter { el in
            ((try? el.getElementsByTag(expr).array()) ?? []).isEmpty == false
        }
    }

    private func extractArgs(_ expr: String, prefix: String) -> (String, String)? {
        var body = String(expr.dropFirst(prefix.count))
        if body.hasSuffix(")") { body = String(body.dropLast()) }
        let parts = splitTopLevelComma(body)
        guard parts.count >= 2 else { return nil }
        return (
            parts[0].trimmingCharacters(in: .whitespaces),
            unquote(parts[1].trimmingCharacters(in: .whitespaces))
        )
    }

    private func splitTopLevelComma(_ str: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var depth = 0
        for ch in str {
            if ch == "'" && !inDouble { inSingle.toggle() }
            if ch == "\"" && !inSingle { inDouble.toggle() }
            if !inSingle && !inDouble {
                if ch == "(" { depth += 1 }
                if ch == ")" { depth -= 1 }
                if ch == "," && depth == 0 {
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

    private func splitLogic(_ str: String, op: String) -> [String]? {
        var result: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var depth = 0
        var idx = str.startIndex
        while idx < str.endIndex {
            let ch = str[idx]
            if ch == "'" && !inDouble { inSingle.toggle() }
            if ch == "\"" && !inSingle { inDouble.toggle() }
            if !inSingle && !inDouble {
                if ch == "(" { depth += 1 }
                if ch == ")" { depth -= 1 }
                if depth == 0,
                   let end = str.index(idx, offsetBy: op.count, limitedBy: str.endIndex),
                   String(str[idx..<end]) == op {
                    result.append(current)
                    current = ""
                    idx = end
                    continue
                }
            }
            current.append(ch)
            idx = str.index(after: idx)
        }
        if !current.isEmpty { result.append(current) }
        return result.count > 1 ? result : nil
    }

    private func resolveValue(_ token: String, on element: Element) -> String? {
        let t = token.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("@") {
            return try? element.attr(String(t.dropFirst()))
        }
        if t == "text()" {
            let tn = element.textNodes()
                .map { $0.text().trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !tn.isEmpty { return tn.joined() }
            return try? element.text()
        }
        if t == "." {
            return try? element.text()
        }
        return t
    }

    private func unquote(_ str: String) -> String {
        var s = str
        if (s.hasPrefix("'") && s.hasSuffix("'")) || (s.hasPrefix("\"") && s.hasSuffix("\"")) {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }

    /// 按 `|` 切分并集，忽略引号与括号内的 `|`
    private func splitUnion(_ xpath: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inSingle = false
        var inDouble = false
        var depth = 0
        for ch in xpath {
            if ch == "'" && !inDouble { inSingle.toggle() }
            if ch == "\"" && !inSingle { inDouble.toggle() }
            if !inSingle && !inDouble {
                if ch == "(" || ch == "[" { depth += 1 }
                if ch == ")" || ch == "]" { depth -= 1 }
                if ch == "|" && depth == 0 {
                    result.append(current)
                    current = ""
                    continue
                }
            }
            current.append(ch)
        }
        if !current.isEmpty { result.append(current) }
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
