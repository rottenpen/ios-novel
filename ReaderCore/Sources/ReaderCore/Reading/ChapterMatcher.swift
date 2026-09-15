import Foundation

/// 不同书源可能插入卷名、公告，优先按章节标题匹配，最后才按目录位置回退。
public enum ChapterMatcher {
    public struct Match: Sendable {
        public let index: Int
        public let matchedTitle: Bool
    }

    public static func match(title: String, index: Int, chapters: [BookChapter]) -> Match? {
        guard !chapters.isEmpty else { return nil }
        let target = normalized(title)
        let matches = chapters.indices.filter {
            !chapters[$0].isVolume && !target.isEmpty && normalized(chapters[$0].title) == target
        }
        if let closest = matches.min(by: { abs($0 - index) < abs($1 - index) }) {
            return Match(index: closest, matchedTitle: true)
        }
        let position = max(0, min(index, chapters.count - 1))
        let readable = chapters.indices.filter { !chapters[$0].isVolume }
        guard let closest = readable.min(by: { abs($0 - position) < abs($1 - position) }) else { return nil }
        return Match(index: closest, matchedTitle: false)
    }

    public static func sameBookName(_ first: String, _ second: String) -> Bool {
        let clean: (String) -> String = {
            $0.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
                .filter { !$0.isWhitespace && !"《》".contains($0) }
        }
        return !clean(first).isEmpty && clean(first) == clean(second)
    }

    private static func normalized(_ title: String) -> String {
        let text = title.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: #"[（(][^）)]*[）)]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*第\s*[0-9零〇一二两三四五六七八九十百千万\s]+[章节回]\s*"#, with: "", options: .regularExpression)
        return text.filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}
