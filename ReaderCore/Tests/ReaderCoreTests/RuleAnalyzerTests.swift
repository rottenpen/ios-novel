import Foundation
import Testing
@testable import ReaderCore

@Suite("RuleAnalyzer 规则切分")
struct RuleAnalyzerTests {

    @Test("单分隔符切分")
    func singleSplit() {
        let analyzer = RuleAnalyzer("class.a@tag.b@text")
        let result = analyzer.splitRule("@")
        #expect(result == ["class.a", "tag.b", "text"])
    }

    @Test("多分隔符 && 切分")
    func andSplit() {
        let analyzer = RuleAnalyzer("class.a@text&&class.b@text")
        let result = analyzer.splitRule("&&", "||", "%%")
        #expect(result == ["class.a@text", "class.b@text"])
        #expect(analyzer.elementsType == "&&")
    }

    @Test("|| 分隔符并记录类型")
    func orSplit() {
        let analyzer = RuleAnalyzer("tag.h1@text||tag.h2@text")
        let result = analyzer.splitRule("&&", "||", "%%")
        #expect(result == ["tag.h1@text", "tag.h2@text"])
        #expect(analyzer.elementsType == "||")
    }

    @Test("%% 交叉合并分隔符")
    func crossSplit() {
        let analyzer = RuleAnalyzer("a@text%%b@text")
        let result = analyzer.splitRule("&&", "||", "%%")
        #expect(result == ["a@text", "b@text"])
        #expect(analyzer.elementsType == "%%")
    }

    /// 核心：分隔符出现在 [] 选择器内部时不得错切
    @Test("方括号内的 && 不被切分")
    func bracketProtectsSeparator() {
        let analyzer = RuleAnalyzer("tag.div[a&&b]@text&&tag.p@text")
        let result = analyzer.splitRule("&&", "||", "%%")
        #expect(result == ["tag.div[a&&b]@text", "tag.p@text"])
    }

    /// 核心：jsonPath 自带的 && 与阅读规则冲突场景
    @Test("圆括号内的分隔符不被切分")
    func parenProtectsSeparator() {
        let analyzer = RuleAnalyzer("$.data[?(@.a&&@.b)]&&$.next")
        let result = analyzer.splitRule("&&", "||", "%%")
        #expect(result == ["$.data[?(@.a&&@.b)]", "$.next"])
    }

    @Test("无分隔符返回原规则")
    func noSeparator() {
        let analyzer = RuleAnalyzer("class.foo@text")
        let result = analyzer.splitRule("&&", "||", "%%")
        #expect(result == ["class.foo@text"])
    }

    @Test("trim 修剪前置 @ 与空白")
    func trimPrefix() {
        let analyzer = RuleAnalyzer("@@class.a@text")
        analyzer.trim()
        let result = analyzer.splitRule("@")
        #expect(result.first == "class.a")
    }

    @Test("三段以上连续切分")
    func multiSegment() {
        let analyzer = RuleAnalyzer("a@text&&b@text&&c@text")
        let result = analyzer.splitRule("&&", "||", "%%")
        #expect(result == ["a@text", "b@text", "c@text"])
    }

    // MARK: - innerRule

    @Test("innerRule 替换 {{}} 内嵌规则")
    func innerRuleReplace() {
        let analyzer = RuleAnalyzer("https://x.com/s?k={{key}}&p=1")
        let result = analyzer.innerRule("{{", "}}") { inner in
            #expect(inner == "key")
            return "斗破"
        }
        #expect(result == "https://x.com/s?k=斗破&p=1")
    }

    @Test("innerRule 多个内嵌规则")
    func innerRuleMultiple() {
        let analyzer = RuleAnalyzer("{{a}}-{{b}}")
        let result = analyzer.innerRule("{{", "}}") { inner in
            inner == "a" ? "1" : "2"
        }
        #expect(result == "1-2")
    }

    @Test("innerRule 无内嵌规则时返回原串")
    func innerRuleNoMatch() {
        let analyzer = RuleAnalyzer("https://x.com/plain")
        let result = analyzer.innerRule("{{", "}}") { _ in "X" }
        #expect(result == "https://x.com/plain")
    }

    @Test("innerRule 未闭合不应死循环")
    func innerRuleUnclosed() {
        let analyzer = RuleAnalyzer("https://x.com/s?k={{key")
        let result = analyzer.innerRule("{{", "}}") { _ in "X" }
        #expect(result.contains("https://x.com/s?k="))
    }

    @Test("长规则不爆栈")
    func longRuleNoStackOverflow() {
        let segment = "class.item@text"
        let long = Array(repeating: segment, count: 300).joined(separator: "&&")
        let analyzer = RuleAnalyzer(long)
        let result = analyzer.splitRule("&&", "||", "%%")
        #expect(result.count == 300)
    }
}
