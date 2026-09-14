// Swift 实现及修改：Yuedu 项目，2026-09-14。
// 来源与许可见仓库根目录 THIRD_PARTY_NOTICES.md（GPL-3.0）。
import Foundation

/// 书源 JSON 规则解析。
///
/// 关键点：解决阅读的 `&&`/`||` 与 JSONPath 自带 `&&`/`||` 的冲突，
/// 并用平衡嵌套（RuleAnalyzer code 模式）替代正则处理 `{$.rule}` 内嵌规则，
/// 避免 JSON 文本中含 `}` 时匹配错误。
public final class AnalyzeByJSonPath {
    private let ctx: Any

    public init(json: Any) {
        if let text = json as? String {
            self.ctx = JSONPath.parse(text) ?? text
        } else {
            self.ctx = json
        }
    }

    /// 原始上下文，供列表规则逐项解析复用
    public var context: Any { ctx }

    public func getString(_ rule: String) -> String? {
        if rule.isEmpty { return nil }
        let ruleAnalyzer = RuleAnalyzer(rule, code: true)
        let rules = ruleAnalyzer.splitRule("&&", "||")

        if rules.count == 1 {
            ruleAnalyzer.resetPos()
            // 替换所有 {$.rule...} 内嵌规则
            let result = ruleAnalyzer.innerRule("{$.") { self.getString($0) }
            if result.isEmpty {
                return JSONPath.string(ctx, path: rule)
            }
            return result
        } else {
            var textList: [String] = []
            for rl in rules {
                if let temp = getString(rl), !temp.isEmpty {
                    textList.append(temp)
                    if ruleAnalyzer.elementsType == "||" { break }
                }
            }
            return textList.isEmpty ? nil : textList.joined(separator: "\n")
        }
    }

    public func getStringList(_ rule: String) -> [String] {
        var result: [String] = []
        if rule.isEmpty { return result }
        let ruleAnalyzer = RuleAnalyzer(rule, code: true)
        let rules = ruleAnalyzer.splitRule("&&", "||", "%%")

        if rules.count == 1 {
            ruleAnalyzer.resetPos()
            let st = ruleAnalyzer.innerRule("{$.") { self.getString($0) }
            if st.isEmpty {
                return JSONPath.stringList(ctx, path: rule)
            }
            result.append(st)
            return result
        } else {
            var results: [[String]] = []
            for rl in rules {
                let temp = getStringList(rl)
                if !temp.isEmpty {
                    results.append(temp)
                    if ruleAnalyzer.elementsType == "||" { break }
                }
            }
            if !results.isEmpty {
                if ruleAnalyzer.elementsType == "%%" {
                    for i in 0..<results[0].count {
                        for temp in results where i < temp.count {
                            result.append(temp[i])
                        }
                    }
                } else {
                    for temp in results {
                        result.append(contentsOf: temp)
                    }
                }
            }
            return result
        }
    }

    /// 获取节点列表（用于 bookList / chapterList 等列表规则）
    public func getList(_ rule: String) -> [Any] {
        if rule.isEmpty { return [] }
        let ruleAnalyzer = RuleAnalyzer(rule, code: true)
        let rules = ruleAnalyzer.splitRule("&&", "||", "%%")

        if rules.count == 1 {
            return JSONPath.nodeList(ctx, path: rule)
        }
        var result: [Any] = []
        for rl in rules {
            let temp = JSONPath.nodeList(ctx, path: rl)
            if !temp.isEmpty {
                result.append(contentsOf: temp)
                if ruleAnalyzer.elementsType == "||" { break }
            }
        }
        return result
    }
}
