// Swift 实现及修改：Yuedu 项目，2026-09-14。
// 来源与许可见仓库根目录 THIRD_PARTY_NOTICES.md（GPL-3.0）。
import Foundation

/// 正则规则解析。
/// 多条正则以 `&&` 串联，前一条的所有匹配拼接后作为后一条的输入。
public enum AnalyzeByRegex {

    /// 获取单条结果的分组列表（index 0 为整体匹配）
    public static func getElement(
        _ res: String,
        regs: [String],
        index: Int = 0
    ) -> [String]? {
        guard index < regs.count else { return nil }
        guard let regex = try? NSRegularExpression(pattern: regs[index]) else { return nil }
        let range = NSRange(res.startIndex..., in: res)
        let matches = regex.matches(in: res, range: range)
        guard !matches.isEmpty else { return nil }

        if index + 1 == regs.count {
            var info: [String] = []
            let match = matches[0]
            for groupIndex in 0..<match.numberOfRanges {
                if let r = Range(match.range(at: groupIndex), in: res) {
                    info.append(String(res[r]))
                } else {
                    info.append("")
                }
            }
            return info
        } else {
            var result = ""
            for match in matches {
                if let r = Range(match.range, in: res) {
                    result += String(res[r])
                }
            }
            return getElement(result, regs: regs, index: index + 1)
        }
    }

    /// 获取多条结果（每条是一组分组）
    public static func getElements(
        _ res: String,
        regs: [String],
        index: Int = 0
    ) -> [[String]] {
        guard index < regs.count else { return [] }
        guard let regex = try? NSRegularExpression(pattern: regs[index]) else { return [] }
        let range = NSRange(res.startIndex..., in: res)
        let matches = regex.matches(in: res, range: range)
        guard !matches.isEmpty else { return [] }

        if index + 1 == regs.count {
            var books: [[String]] = []
            for match in matches {
                var info: [String] = []
                for groupIndex in 0..<match.numberOfRanges {
                    if let r = Range(match.range(at: groupIndex), in: res) {
                        info.append(String(res[r]))
                    } else {
                        info.append("")
                    }
                }
                books.append(info)
            }
            return books
        } else {
            var result = ""
            for match in matches {
                if let r = Range(match.range, in: res) {
                    result += String(res[r])
                }
            }
            return getElements(result, regs: regs, index: index + 1)
        }
    }
}
