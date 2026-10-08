import Foundation
import CoreText
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// 正文内嵌图片锚点：在全文 UTF-16 偏移处替换 `<img>` 占位符。
public struct ImageAnchor: Codable, Sendable, Hashable {
    public let offset: Int
    public let url: String

    public init(offset: Int, url: String) {
        self.offset = offset
        self.url = url
    }
}

public struct PageLayout: Hashable, Sendable {
    public let width: Double
    public let height: Double
    public let fontSize: Double
    public let lineSpacing: Double
    /// 正文字体的 PostScript / 家族名，默认宋体。
    /// 作为 Hashable 的一部分，切换字体会触发重新分页。
    public let fontName: String

    public init(width: Double, height: Double, fontSize: Double,
                lineSpacing: Double, fontName: String = "Songti SC") {
        self.width = width
        self.height = height
        self.fontSize = fontSize
        self.lineSpacing = lineSpacing
        self.fontName = fontName
    }

    /// 按名创建字体；名称无效时回退系统字体，保证分页不因字体缺失失败。
    public static func font(name: String, size: Double) -> CTFont {
        let created = CTFontCreateWithName(name as CFString, size, nil)
        // CTFontCreateWithName 对未知名会返回 Helvetica 之类，这里直接用其结果即可
        return created
    }
}

/// 使用同一份不可变排版结果计算页范围和绘制，避免页末文字截断。
public final class TextPagination: @unchecked Sendable {
    public let text: String
    public let ranges: [NSRange]
    public let layout: PageLayout
    /// 图片锚点：分页时占位符 `\u{FFFC}` 在排版中占固定行高，绘制阶段替换为真实图片。
    public let images: [ImageAnchor]
    private let framesetter: CTFramesetter

    public enum LayoutError: LocalizedError {
        case insufficientSpace
        public var errorDescription: String? { "当前区域不足以显示正文，请调整字号或屏幕方向" }
    }

    /// 图片占位符在排版中的固定行高（App 层绘制时按真实宽高比缩放）。
    public static let imagePlaceholderHeight: CGFloat = 200

    public init(text: String, layout: PageLayout, images: [ImageAnchor] = []) throws {
        guard layout.width.isFinite, layout.height.isFinite, layout.fontSize.isFinite,
              layout.lineSpacing.isFinite, layout.width > 0, layout.height > 0,
              layout.fontSize > 0, layout.lineSpacing >= 0 else {
            throw LayoutError.insufficientSpace
        }
        self.text = text
        self.layout = layout
        self.images = images
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = layout.lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: PageLayout.font(name: layout.fontName, size: layout.fontSize),
            .paragraphStyle: paragraph,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ])
        // 为图片占位符设置 CTRunDelegate，使其占据固定行高，正文不重叠
        for image in images where image.offset >= 0 && image.offset < (text as NSString).length {
            let delegate = ImageRunDelegate.make(height: Self.imagePlaceholderHeight)
            attributed.addAttribute(
                NSAttributedString.Key(kCTRunDelegateAttributeName as String),
                value: delegate,
                range: NSRange(location: image.offset, length: 1)
            )
        }
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

    /// 计算某页中图片锚点的绘制矩形（y 为 CoreText 翻转坐标系的基线位置）。
    /// App 层拿到后按自己坐标换算绘制；图片最终宽度不超过给定 maxWidth。
    public func imageRects(at page: Int, maxWidth: CGFloat) -> [(ImageAnchor, CGRect)] {
        guard ranges.indices.contains(page) else { return [] }
        let range = ranges[page]
        guard let frame = frame(at: page) else { return [] }
        let lines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lines.count), &origins)

        let height = Self.imagePlaceholderHeight
        var result: [(ImageAnchor, CGRect)] = []
        for image in images where range.location <= image.offset && image.offset < range.location + range.length {
            for (i, line) in lines.enumerated() {
                let lineRange = CTLineGetStringRange(line)
                guard image.offset >= lineRange.location && image.offset < lineRange.location + lineRange.length else { continue }
                let x = CTLineGetOffsetForStringIndex(line, image.offset, nil)
                let y = origins[i].y
                let width = min(maxWidth, layout.width)
                result.append((image, CGRect(x: x, y: y - height, width: width, height: height)))
                break
            }
        }
        return result
    }
}

/// CTRunDelegate 回调：让图片占位符占据固定行高（与 TextPagination.imagePlaceholderHeight 一致）。
/// 注意：C 回调不能捕获上下文，行高使用编译期常量。
private enum ImageRunDelegate {
    static func make(height: CGFloat) -> CTRunDelegate {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { _ in },
            getAscent: { _ in 200 },
            getDescent: { _ in 0 },
            getWidth: { _ in 0 }
        )
        return CTRunDelegateCreate(&callbacks, nil)!
    }
}
