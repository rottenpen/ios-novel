// Swift 实现及修改：Yuedu 项目，2026-09-14。
// 来源与许可见仓库根目录 THIRD_PARTY_NOTICES.md（GPL-3.0）。
import Foundation

/// 通用规则切分处理。
///
/// 规则切分约定：
/// - 不使用正则，只在字符序列中标记查找字段的首尾，返回时才切片，避免中间字符串分配。
/// - 解决 jsonPath 自带的 `&&` / `||` 与阅读规则冲突，以及规则正则或字符串中
///   包含 `&&`、`||`、`%%`、`@` 导致的错切问题。
/// - 为避免深层规则匹配时递归耗尽栈，使用
///   显式迭代（外层 while + 状态机），避免长规则递归过深爆栈。
public final class RuleAnalyzer {
    private let queue: [Character]
    private let queueString: String
    private var pos = 0
    private var start = 0
    private var startX = 0

    private var rule: [String] = []
    private var step = 0
    /// 当前分割字符串（`&&` / `||` / `%%` 等）
    public private(set) var elementsType = ""

    private let isCode: Bool

    private static let escapeChar: Character = "\\"

    public init(_ data: String, code: Bool = false) {
        self.queueString = data
        self.queue = Array(data)
        self.isCode = code
    }

    // MARK: - Substring helpers (Character array based, O(1) index math)

    private func slice(_ from: Int, _ to: Int) -> String {
        guard from < to, from >= 0, to <= queue.count else { return "" }
        return String(queue[from..<to])
    }

    private func slice(from: Int) -> String {
        guard from >= 0, from < queue.count else { return "" }
        return String(queue[from...])
    }

    /// 修剪当前规则之前的 `@` 或空白符
    public func trim() {
        guard pos < queue.count else { return }
        if queue[pos] == "@" || queue[pos].asciiValue.map({ $0 < 33 }) == true
            || (queue[pos].asciiValue == nil && queue[pos].isWhitespace) {
            pos += 1
            while pos < queue.count,
                  queue[pos] == "@"
                    || (queue[pos].asciiValue.map { $0 < 33 } == true)
                    || (queue[pos].asciiValue == nil && queue[pos].isWhitespace) {
                pos += 1
            }
            start = pos
            startX = pos
        }
    }

    /// 将 pos 重置为 0，方便复用
    public func resetPos() {
        pos = 0
        startX = 0
    }

    /// 从剩余字串中拉出一个字符串，直到但不包括匹配序列。
    private func consumeTo(_ seq: String) -> Bool {
        start = pos
        guard let offset = indexOf(seq, from: pos) else { return false }
        pos = offset
        return true
    }

    private func indexOf(_ seq: String, from: Int) -> Int? {
        let seqChars = Array(seq)
        guard !seqChars.isEmpty, from <= queue.count else { return nil }
        if seqChars.count > queue.count { return nil }
        var i = from
        let limit = queue.count - seqChars.count
        while i <= limit {
            var matched = true
            for j in 0..<seqChars.count where queue[i + j] != seqChars[j] {
                matched = false
                break
            }
            if matched { return i }
            i += 1
        }
        return nil
    }

    private func regionMatches(_ index: Int, _ seq: [Character]) -> Bool {
        guard index + seq.count <= queue.count else { return false }
        for j in 0..<seq.count where queue[index + j] != seq[j] {
            return false
        }
        return true
    }

    /// 从剩余字串中拉出一个字符串，直到但不包括匹配序列中任意一项，或剩余字串用完。
    private func consumeToAny(_ seq: [String]) -> Bool {
        var p = pos
        let seqChars = seq.map { Array($0) }
        while p != queue.count {
            for chars in seqChars where regionMatches(p, chars) {
                step = chars.count
                pos = p
                return true
            }
            p += 1
        }
        return false
    }

    /// 查找任意字符首次出现的位置
    private func findToAny(_ chars: [Character]) -> Int {
        var p = pos
        while p != queue.count {
            for c in chars where queue[p] == c {
                return p
            }
            p += 1
        }
        return -1
    }

    /// 拉出一个非内嵌代码平衡组，存在转义文本（用于 JSON / JavaScript）。
    private func chompCodeBalanced(_ open: Character, _ close: Character) -> Bool {
        var p = pos
        var depth = 0
        var otherDepth = 0
        var inSingleQuote = false
        var inDoubleQuote = false

        repeat {
            if p == queue.count { break }
            let c = queue[p]
            p += 1
            if c != Self.escapeChar {
                if c == "'" && !inDoubleQuote {
                    inSingleQuote.toggle()
                } else if c == "\"" && !inSingleQuote {
                    inDoubleQuote.toggle()
                }
                if inSingleQuote || inDoubleQuote { continue }

                if c == "[" {
                    depth += 1
                } else if c == "]" {
                    depth -= 1
                } else if depth == 0 {
                    if c == open {
                        otherDepth += 1
                    } else if c == close {
                        otherDepth -= 1
                    }
                }
            } else {
                p += 1
            }
        } while depth > 0 || otherDepth > 0

        if depth > 0 || otherDepth > 0 { return false }
        pos = p
        return true
    }

    /// 拉出一个规则平衡组。xpath 和 jsoup 中引号内转义字符无效。
    private func chompRuleBalanced(_ open: Character, _ close: Character) -> Bool {
        var p = pos
        var depth = 0
        var inSingleQuote = false
        var inDoubleQuote = false

        repeat {
            if p == queue.count { break }
            let c = queue[p]
            p += 1
            if c == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if c == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
            }

            if inSingleQuote || inDoubleQuote {
                continue
            } else if c == "\\" {
                p += 1
                continue
            }

            if c == open {
                depth += 1
            } else if c == close {
                depth -= 1
            }
        } while depth > 0

        if depth > 0 { return false }
        pos = p
        return true
    }

    private func chompBalanced(_ open: Character, _ close: Character) -> Bool {
        isCode ? chompCodeBalanced(open, close) : chompRuleBalanced(open, close)
    }

    // MARK: - splitRule

    /// 切分规则，先定位首段再按相同分隔类型匹配后续段，
    /// 用显式循环替代尾递归。
    @discardableResult
    public func splitRule(_ split: String...) -> [String] {
        splitRule(split)
    }

    @discardableResult
    public func splitRule(_ split: [String]) -> [String] {
        // Phase A: 首段匹配
        if split.count == 1 {
            elementsType = split[0]
            if !consumeTo(elementsType) {
                rule.append(slice(from: startX))
                return rule
            }
            step = Array(elementsType).count
            return splitRuleNext()
        }

        while true {
            if !consumeToAny(split) {
                rule.append(slice(from: startX))
                return rule
            }

            let end = pos
            pos = start

            var restartOuter = false

            while true {
                let st = findToAny(["[", "("])

                if st == -1 {
                    rule = [slice(startX, end)]
                    elementsType = slice(end, end + step)
                    pos = end + step
                    while consumeTo(elementsType) {
                        rule.append(slice(start, pos))
                        pos += step
                    }
                    rule.append(slice(from: pos))
                    return rule
                }

                if st > end {
                    rule = [slice(startX, end)]
                    elementsType = slice(end, end + step)
                    pos = end + step
                    while consumeTo(elementsType), pos < st {
                        rule.append(slice(start, pos))
                        pos += step
                    }
                    if pos > st {
                        startX = start
                        return splitRuleNext()
                    } else {
                        rule.append(slice(from: pos))
                        return rule
                    }
                }

                pos = st
                let next: Character = queue[pos] == "[" ? "]" : ")"
                if !chompBalanced(queue[pos], next) {
                    // 不平衡即视为规则错误，这里降级为返回整体规则，
                    // 避免在 UI 层因单条书源规则异常导致崩溃。
                    rule.append(slice(from: startX))
                    return rule
                }

                if end <= pos {
                    // 退出内层 do-while，回到首段匹配
                    start = pos
                    restartOuter = true
                    break
                }
            }

            if restartOuter { continue }
        }
    }

    /// 二段匹配：elementsType 已确定，直接按其查找。
    private func splitRuleNext() -> [String] {
        while true {
            let end = pos
            pos = start

            var needConsumeMore = false

            while true {
                let st = findToAny(["[", "("])

                if st == -1 {
                    rule.append(slice(startX, end))
                    pos = end + step
                    while consumeTo(elementsType) {
                        rule.append(slice(start, pos))
                        pos += step
                    }
                    rule.append(slice(from: pos))
                    return rule
                }

                if st > end {
                    rule.append(slice(startX, end))
                    pos = end + step
                    while consumeTo(elementsType), pos < st {
                        rule.append(slice(start, pos))
                        pos += step
                    }
                    if pos > st {
                        startX = start
                        // 继续二段匹配（对应递归调用 splitRule()）
                        needConsumeMore = false
                        break
                    } else {
                        rule.append(slice(from: pos))
                        return rule
                    }
                }

                pos = st
                let next: Character = queue[pos] == "[" ? "]" : ")"
                if !chompBalanced(queue[pos], next) {
                    rule.append(slice(from: startX))
                    return rule
                }

                if end <= pos {
                    start = pos
                    needConsumeMore = true
                    break
                }
            }

            if needConsumeMore {
                if !consumeTo(elementsType) {
                    rule.append(slice(from: startX))
                    return rule
                }
            }
        }
    }

    // MARK: - innerRule

    /// 替换内嵌规则（平衡组形式，如 `{{...}}` 中的 `{$.` ）。
    /// 替换由步长指定的规则片段。
    public func innerRule(
        _ inner: String,
        startStep: Int = 1,
        endStep: Int = 1,
        _ fr: (String) -> String?
    ) -> String {
        var st = ""
        while consumeTo(inner) {
            let posPre = pos
            if chompCodeBalanced("{", "}") {
                let frv = fr(slice(posPre + startStep, pos - endStep))
                if let frv, !frv.isEmpty {
                    st += slice(startX, posPre) + frv
                    startX = pos
                    continue
                }
            }
            pos += Array(inner).count
        }
        if startX == 0 { return "" }
        return st + slice(from: startX)
    }

    /// 替换内嵌规则（起止串形式，如 `{{` ... `}}`）。
    /// 替换成对标记之间的规则片段。
    public func innerRule(
        _ startStr: String,
        _ endStr: String,
        _ fr: (String) -> String?
    ) -> String {
        var st = ""
        let startLen = Array(startStr).count
        let endLen = Array(endStr).count
        while consumeTo(startStr) {
            pos += startLen
            let posPre = pos
            if consumeTo(endStr) {
                let frv = fr(slice(posPre, pos)) ?? ""
                st += slice(startX, posPre - startLen) + frv
                pos += endLen
                startX = pos
            } else {
                // 没有闭合符，跳出避免死循环
                break
            }
        }
        if startX == 0 { return queueString }
        return st + slice(from: startX)
    }
}
