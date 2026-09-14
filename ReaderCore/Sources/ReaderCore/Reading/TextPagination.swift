import Foundation
import CoreText
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

public struct PageLayout: Hashable, Sendable {
    public let width: Double
    public let height: Double
    public let fontSize: Double
    public let lineSpacing: Double

    public init(width: Double, height: Double, fontSize: Double, lineSpacing: Double) {
        self.width = width
        self.height = height
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
    }
}

/// 使用同一份不可变排版结果计算页范围和绘制，避免页末文字截断。
public final class TextPagination: @unchecked Sendable {
    public let text: String
    public let ranges: [NSRange]
    public let layout: PageLayout
    private let framesetter: CTFramesetter

    public enum LayoutError: LocalizedError {
        case insufficientSpace
        public var errorDescription: String? { "当前区域不足以显示正文，请调整字号或屏幕方向" }
    }

    public init(text: String, layout: PageLayout) throws {
        guard layout.width.isFinite, layout.height.isFinite, layout.fontSize.isFinite,
              layout.lineSpacing.isFinite, layout.width > 0, layout.height > 0,
              layout.fontSize > 0, layout.lineSpacing >= 0 else {
            throw LayoutError.insufficientSpace
        }
        self.text = text
        self.layout = layout
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = layout.lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string: text, attributes: [
            .font: CTFontCreateWithName("Songti SC" as CFString, layout.fontSize, nil),
            .paragraphStyle: paragraph,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ])
        framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: layout.width, height: layout.height), transform: nil)
        let source = text as NSString
        var pages: [NSRange] = []
        var offset = 0
        while offset < source.length {
            try Task.checkCancellation()
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            var end = offset + visible.length
            // CoreText 的 UTF-16 范围可能落在组合字符内部，整组移到下一页。
            if end < source.length {
                let character = source.rangeOfComposedCharacterSequence(at: end)
                if character.location < end { end = character.location }
            }
            guard end > offset else { throw LayoutError.insufficientSpace }
            pages.append(NSRange(location: offset, length: end - offset))
            offset = end
        }
        ranges = pages.isEmpty ? [NSRange(location: 0, length: 0)] : pages
    }

    public func page(containing offset: Int) -> Int {
        let target = max(0, min(offset, (text as NSString).length - 1))
        var low = 0
        var high = ranges.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if ranges[middle].location <= target { low = middle } else { high = middle - 1 }
        }
        return low
    }

    public func text(at page: Int) -> String {
        guard ranges.indices.contains(page) else { return "" }
        return (text as NSString).substring(with: ranges[page])
    }

    public func frame(at page: Int) -> CTFrame? {
        guard ranges.indices.contains(page), ranges[page].length > 0 else { return nil }
        let range = ranges[page]
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: layout.width, height: layout.height), transform: nil)
        return CTFramesetterCreateFrame(framesetter, CFRange(location: range.location, length: range.length), path, nil)
    }
}
