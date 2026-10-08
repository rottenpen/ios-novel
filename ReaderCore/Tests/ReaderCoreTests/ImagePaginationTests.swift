import Foundation
import Testing
@testable import ReaderCore

@Suite("正文图片分页")
struct ImagePaginationTests {

    @Test("占位符正常分页且图片矩形可定位")
    func paginateWithImagePlaceholder() throws {
        let text = "第一章正文内容，用来测试分页是否能把图片占位符当作正常字符排版。\u{FFFC}\n后面的文字继续。"
        let layout = PageLayout(width: 320, height: 480, fontSize: 18, lineSpacing: 4)
        let anchor = ImageAnchor(offset: (text as NSString).range(of: "\u{FFFC}").location, url: "https://example.com/a.png")
        let pages = try TextPagination(text: text, layout: layout, images: [anchor])

        #expect(!pages.ranges.isEmpty)
        // 找到占位符所在页
        let placeholderPage = pages.page(containing: anchor.offset)
        let rects = pages.imageRects(at: placeholderPage, maxWidth: 300)
        #expect(!rects.isEmpty)
        #expect(rects.first?.0.url == "https://example.com/a.png")
        #expect((rects.first?.1.height ?? 0) > 0)
    }

    @Test("无图片时 imageRects 为空")
    func noImagesYieldsEmptyRects() throws {
        let layout = PageLayout(width: 320, height: 480, fontSize: 18, lineSpacing: 4)
        let pages = try TextPagination(text: "纯文本，没有任何图片占位符。", layout: layout)
        #expect(pages.imageRects(at: 0, maxWidth: 300).isEmpty)
    }

    @Test("越界图片锚点不崩溃")
    func outOfRangeAnchorIgnored() throws {
        let layout = PageLayout(width: 320, height: 480, fontSize: 18, lineSpacing: 4)
        let pages = try TextPagination(
            text: "短文本",
            layout: layout,
            images: [ImageAnchor(offset: 999, url: "https://example.com/x.png")]
        )
        #expect(!pages.ranges.isEmpty)
    }
}
