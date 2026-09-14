// Swift 实现及修改：Yuedu 项目，2026-09-14。
// 来源与许可见仓库根目录 THIRD_PARTY_NOTICES.md（GPL-3.0）。
import Foundation
import SwiftSoup

/// 书源 HTML 规则解析。
///
/// 支持的规则写法：
/// 1. 阅读原生写法：`class.foo.0@tag.a.-1@text`，`.` 选择 / `!` 排除，索引可为负数，
///    支持 `start:end:step` 区间，如 `tag.div.-1:10:2`、`tag.div!0:3`
/// 2. JSONPath 风格索引：`tag.div[-1, 3:-2:-10, 2]`，`[!...]` 表示排除
/// 3. `@CSS:` 前缀走标准 CSS 选择器
/// 4. `&&` / `||` / `%%` 组合：与 / 或（短路）/ 交叉合并
/// 5. 末段取值：`text`、`textNodes`、`ownText`、`html`、`all`，其余视为属性名
public final class AnalyzeByJSoup {
    private var element: Element

    public init(doc: Any) throws {
        self.element = try Self.parse(doc)
    }

    private static func parse(_ doc: Any) throws -> Element {
        if let element = doc as? Element {
            return element
        }
        let text = String(describing: doc)
        // XML 文档使用 XML parser。
        if text.lowercased().hasPrefix("<?xml") {
            return try SwiftSoup.parse(text, "", Parser.xmlParser())
        }
        return try SwiftSoup.parse(text)
    }

    // MARK: - Public API

    /// 获取元素列表
    public func getElements(_ rule: String) throws -> Elements {
        try getElements(element, rule)
    }

    /// 合并内容列表得到单个字符串（多项以换行连接）
    public func getString(_ ruleStr: String) throws -> String? {
        if ruleStr.isEmpty { return nil }
        let list = try getStringList(ruleStr)
        if list.isEmpty { return nil }
        if list.count == 1 { return list[0] }
        return list.joined(separator: "\n")
    }

    /// 获取第一个字符串
    public func getString0(_ ruleStr: String) throws -> String {
        let list = try getStringList(ruleStr)
        return list.isEmpty ? "" : list[0]
    }

    /// 获取所有内容列表
    public func getStringList(_ ruleStr: String) throws -> [String] {
        var textS: [String] = []
        if ruleStr.isEmpty { return textS }

        let sourceRule = SourceRule(ruleStr)

        if sourceRule.elementsRule.isEmpty {
            textS.append(element.data())
            return textS
        }

        let ruleAnalyzer = RuleAnalyzer(sourceRule.elementsRule)
        let ruleStrS = ruleAnalyzer.splitRule("&&", "||", "%%")

        var results: [[String]] = []
        for ruleStrX in ruleStrS {
            var temp: [String]?
            if sourceRule.isCss {
                if let lastIndex = ruleStrX.lastIndex(of: "@") {
                    let selector = String(ruleStrX[ruleStrX.startIndex..<lastIndex])
                    let lastRule = String(ruleStrX[ruleStrX.index(after: lastIndex)...])
                    let selected = try element.select(selector)
                    temp = try getResultLast(selected, lastRule)
                } else {
                    temp = nil
                }
            } else {
                temp = try getResultList(ruleStrX)
            }

            if let temp, !temp.isEmpty {
                results.append(temp)
                if ruleAnalyzer.elementsType == "||" { break }
            }
        }

        if !results.isEmpty {
            if ruleAnalyzer.elementsType == "%%" {
                // 交叉合并：按下标轮转取值
                for i in 0..<results[0].count {
                    for temp in results where i < temp.count {
                        textS.append(temp[i])
                    }
                }
            } else {
                for temp in results {
                    textS.append(contentsOf: temp)
                }
            }
        }
        return textS
    }

    // MARK: - Internals

    private func getElements(_ temp: Element?, _ rule: String) throws -> Elements {
        guard let temp, !rule.isEmpty else { return Elements() }

        let elements = Elements()
        let sourceRule = SourceRule(rule)
        let ruleAnalyzer = RuleAnalyzer(sourceRule.elementsRule)
        let ruleStrS = ruleAnalyzer.splitRule("&&", "||", "%%")

        var elementsList: [Elements] = []
        if sourceRule.isCss {
            for ruleStr in ruleStrS {
                let tempS = try temp.select(ruleStr)
                elementsList.append(tempS)
                if tempS.size() > 0 && ruleAnalyzer.elementsType == "||" { break }
            }
        } else {
            for ruleStr in ruleStrS {
                let rsRule = RuleAnalyzer(ruleStr)
                rsRule.trim()
                let rs = rsRule.splitRule("@")

                let el: Elements
                if rs.count > 1 {
                    var acc: [Element] = [temp]
                    for rl in rs {
                        var es: [Element] = []
                        for et in acc {
                            es.append(contentsOf: try getElements(et, rl).array())
                        }
                        acc = es
                    }
                    el = Elements(acc)
                } else {
                    el = try ElementsSingle().getElementsSingle(temp, ruleStr)
                }

                elementsList.append(el)
                if el.size() > 0 && ruleAnalyzer.elementsType == "||" { break }
            }
        }

        if !elementsList.isEmpty {
            if ruleAnalyzer.elementsType == "%%" {
                for i in 0..<elementsList[0].size() {
                    for es in elementsList where i < es.size() {
                        elements.add(es.get(i))
                    }
                }
            } else {
                for es in elementsList {
                    for el in es.array() { elements.add(el) }
                }
            }
        }
        return elements
    }

    private func getResultList(_ ruleStr: String) throws -> [String]? {
        if ruleStr.isEmpty { return nil }

        var elements: [Element] = [element]

        let rule = RuleAnalyzer(ruleStr)
        rule.trim()
        let rules = rule.splitRule("@")

        let last = rules.count - 1
        if last < 0 { return nil }
        for i in 0..<last {
            var es: [Element] = []
            for elt in elements {
                es.append(contentsOf: try ElementsSingle().getElementsSingle(elt, rules[i]).array())
            }
            elements = es
        }
        if elements.isEmpty { return nil }
        return try getResultLast(Elements(elements), rules[last])
    }

    /// 根据最后一个规则取值
    private func getResultLast(_ elements: Elements, _ lastRule: String) throws -> [String] {
        var textS: [String] = []
        switch lastRule {
        case "text":
            for element in elements.array() {
                let text = try element.text()
                if !text.isEmpty { textS.append(text) }
            }

        case "textNodes":
            for element in elements.array() {
                var tn: [String] = []
                for item in element.textNodes() {
                    let text = item.text().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { tn.append(text) }
                }
                if !tn.isEmpty { textS.append(tn.joined(separator: "\n")) }
            }

        case "ownText":
            for element in elements.array() {
                let text = element.ownText()
                if !text.isEmpty { textS.append(text) }
            }

        case "html":
            try elements.select("script").remove()
            try elements.select("style").remove()
            let html = try elements.outerHtml()
            if !html.isEmpty { textS.append(html) }

        case "all":
            textS.append(try elements.outerHtml())

        default:
            for element in elements.array() {
                let url = try element.attr(lastRule)
                if url.trimmingCharacters(in: .whitespaces).isEmpty || textS.contains(url) {
                    continue
                }
                textS.append(url)
            }
        }
        return textS
    }

    // MARK: - SourceRule

    private struct SourceRule {
        var isCss = false
        var elementsRule: String

        init(_ ruleStr: String) {
            if ruleStr.lowercased().hasPrefix("@css:") {
                isCss = true
                elementsRule = String(ruleStr.dropFirst(5))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                elementsRule = ruleStr
            }
        }
    }

    // MARK: - ElementsSingle

    /// 索引语义解析。
    /// 索引区间用 Triple(start, end, step) 表达，这里用具名结构体替代。
    final class ElementsSingle {
        private enum IndexItem {
            case single(Int)
            case range(start: Int?, end: Int?, step: Int)
        }

        private var split: Character = "."
        private var beforeRule: String = ""
        private var indexDefault: [Int] = []
        private var indexes: [IndexItem] = []

        func getElementsSingle(_ temp: Element, _ rule: String) throws -> Elements {
            findIndexSet(rule)

            var elements: Elements
            if beforeRule.isEmpty {
                elements = temp.children()
            } else {
                let rules = beforeRule.components(separatedBy: ".")
                switch rules[0] {
                case "children":
                    elements = temp.children()
                case "class":
                    elements = rules.count > 1
                        ? try temp.getElementsByClass(rules[1]) : Elements()
                case "tag":
                    elements = rules.count > 1
                        ? try temp.getElementsByTag(rules[1]) : Elements()
                case "id":
                    elements = rules.count > 1
                        ? try temp.getElementsByAttributeValue("id", rules[1]) : Elements()
                case "text":
                    // SwiftSoup 无 getElementsContainingOwnText，用 :containsOwn 选择器等价实现
                    if rules.count > 1 {
                        let needle = rules[1].replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: ")", with: "\\)")
                        elements = try temp.select(":containsOwn(\(needle))")
                    } else {
                        elements = Elements()
                    }
                default:
                    elements = try temp.select(beforeRule)
                }
            }

            let len = elements.size()
            // 保持逆序遍历以还原插入顺序
            let lastIndexes = indexDefault.isEmpty ? indexes.count - 1 : indexDefault.count - 1
            var indexSet: [Int] = []

            func appendUnique(_ value: Int) {
                if !indexSet.contains(value) { indexSet.append(value) }
            }

            if indexes.isEmpty {
                guard lastIndexes >= 0 else {
                    return applyFilter(elements, indexSet, len)
                }
                for ix in stride(from: lastIndexes, through: 0, by: -1) {
                    let it = indexDefault[ix]
                    if it >= 0 && it < len {
                        appendUnique(it)
                    } else if it < 0 && len >= -it {
                        appendUnique(it + len)
                    }
                }
            } else {
                guard lastIndexes >= 0 else {
                    return applyFilter(elements, indexSet, len)
                }
                for ix in stride(from: lastIndexes, through: 0, by: -1) {
                    switch indexes[ix] {
                    case let .range(startX, endX, stepX):
                        guard len > 0 else { continue }
                        let start: Int
                        if let startX {
                            if startX >= 0 {
                                start = startX < len ? startX : len - 1
                            } else {
                                start = -startX <= len ? len + startX : 0
                            }
                        } else {
                            start = 0
                        }

                        let end: Int
                        if let endX {
                            if endX >= 0 {
                                end = endX < len ? endX : len - 1
                            } else {
                                end = -endX <= len ? len + endX : 0
                            }
                        } else {
                            end = len - 1
                        }

                        if start == end || stepX >= len {
                            appendUnique(start)
                            continue
                        }

                        let step: Int
                        if stepX > 0 {
                            step = stepX
                        } else if -stepX < len {
                            step = stepX + len
                        } else {
                            step = 1
                        }
                        let safeStep = max(1, abs(step))

                        if end > start {
                            for v in stride(from: start, through: end, by: safeStep) {
                                appendUnique(v)
                            }
                        } else {
                            for v in stride(from: start, through: end, by: -safeStep) {
                                appendUnique(v)
                            }
                        }

                    case let .single(it):
                        if it >= 0 && it < len {
                            appendUnique(it)
                        } else if it < 0 && len >= -it {
                            appendUnique(it + len)
                        }
                    }
                }
            }

            return applyFilter(elements, indexSet, len)
        }

        private func applyFilter(_ elements: Elements, _ indexSet: [Int], _ len: Int) -> Elements {
            if split == "!" {
                // 排除模式
                let excluded = Set(indexSet)
                var result: [Element] = []
                for (i, el) in elements.array().enumerated() where !excluded.contains(i) {
                    result.append(el)
                }
                return Elements(result)
            } else if split == "." {
                // 选择模式
                var result: [Element] = []
                for pcInt in indexSet where pcInt >= 0 && pcInt < len {
                    result.append(elements.get(pcInt))
                }
                return Elements(result)
            }
            return elements
        }

        /// 从规则尾部逆向解析索引。
        private func findIndexSet(_ rule: String) {
            let rus = Array(rule.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !rus.isEmpty else {
                split = " "
                beforeRule = ""
                return
            }

            var len = rus.count
            var curInt: Int?
            var curMinus = false
            var curList: [Int?] = []
            var l = ""

            let head = rus[rus.count - 1] == "]"

            if head {
                len -= 1  // 跳过尾部 ']'
                len -= 1
                while len >= 0 {
                    var rl = rus[len]
                    if rl == " " {
                        len -= 1
                        continue
                    }

                    if rl.isNumber {
                        l = String(rl) + l
                        len -= 1
                        continue
                    } else if rl == "-" {
                        curMinus = true
                        len -= 1
                        continue
                    } else {
                        curInt = l.isEmpty ? nil : (curMinus ? -(Int(l) ?? 0) : Int(l))

                        if rl == ":" {
                            curList.append(curInt)
                        } else {
                            if curList.isEmpty {
                                guard let curInt else { break }
                                indexes.append(.single(curInt))
                            } else {
                                let step = curList.count == 2 ? (curList.first ?? 1) : 1
                                indexes.append(
                                    .range(
                                        start: curInt,
                                        end: curList.last ?? nil,
                                        step: step ?? 1
                                    )
                                )
                                curList.removeAll()
                            }

                            if rl == "!" {
                                split = "!"
                                repeat {
                                    len -= 1
                                    guard len >= 0 else { break }
                                    rl = rus[len]
                                } while len > 0 && rl == " "
                            }

                            if rl == "[" {
                                beforeRule = String(rus[0..<max(0, len)])
                                return
                            }

                            if rl != "," { break }
                        }

                        l = ""
                        curMinus = false
                        len -= 1
                    }
                }
            } else {
                len -= 1
                while len >= 0 {
                    let rl = rus[len]
                    if rl == " " {
                        len -= 1
                        continue
                    }

                    if rl.isNumber {
                        l = String(rl) + l
                        len -= 1
                        continue
                    } else if rl == "-" {
                        curMinus = true
                        len -= 1
                        continue
                    } else {
                        if rl == "!" || rl == "." || rl == ":" {
                            if let value = Int(l) {
                                indexDefault.append(curMinus ? -value : value)
                            }
                            if rl != ":" {
                                split = rl
                                beforeRule = String(rus[0..<len])
                                return
                            }
                        } else {
                            break
                        }
                        l = ""
                        curMinus = false
                        len -= 1
                    }
                }
            }

            split = " "
            beforeRule = String(rus)
        }
    }
}
