import Foundation
import CoreText
import Testing
@testable import ReaderCore

@Suite("分页与阅读位置")
struct ReadingTests {
    private let prose = String(repeating: "　　春风吹过书页，远处的灯火渐渐亮起。👨‍👩‍👧‍👦 e\u{301} 𠮷。\n新的一段从这里开始，继续阅读。\n", count: 120)

    @Test("不同排版逐页完整覆盖正文", arguments: [14.0, 19.0, 30.0], [2.0, 9.0, 20.0])
    func ranges(font: Double, spacing: Double) throws {
        for size in [(132.0, 180.0), (350.0, 680.0), (720.0, 220.0)] {
            let pages = try TextPagination(text: prose, layout: .init(width: size.0, height: size.1, fontSize: font, lineSpacing: spacing))
            #expect(pages.ranges.count > 1)
            var end = 0
            for (index, range) in pages.ranges.enumerated() {
                #expect(range.location == end)
                #expect(range.length > 0)
                #expect((prose as NSString).rangeOfComposedCharacterSequence(at: range.location).location == range.location)
                #expect(pages.page(containing: range.location) == index)
                let frame = try #require(pages.frame(at: index))
                #expect(CTFrameGetVisibleStringRange(frame).length == range.length)
                end = NSMaxRange(range)
            }
            #expect(end == (prose as NSString).length)
            #expect(pages.ranges.indices.map { pages.text(at: $0) }.joined() == prose)
            #expect(pages.page(containing: Int.max) == pages.ranges.count - 1)
            #expect(pages.page(containing: -1) == 0)
        }
    }

    @Test("空正文、长段落和空间不足")
    func boundaries() throws {
        let layout = PageLayout(width: 300, height: 500, fontSize: 19, lineSpacing: 9)
        #expect(try TextPagination(text: "", layout: layout).ranges == [NSRange(location: 0, length: 0)])
        let long = String(repeating: "没有换行的一段正文。", count: 1000)
        let pages = try TextPagination(text: long, layout: layout)
        #expect(pages.ranges.indices.map { pages.text(at: $0) }.joined() == long)
        #expect(throws: TextPagination.LayoutError.self) {
            try TextPagination(text: "正文", layout: .init(width: 1, height: 1, fontSize: 30, lineSpacing: 20))
        }
    }

    @Test("跨章首尾、排版恢复、过期加载和有界缓存")
    @MainActor func session() async throws {
        let text = prose
        var saved: [(Int, Int)] = []
        let reader = ReadingSession(chapterCount: 20, startIndex: 0)
        reader.start(load: { index in
            if index == 4 { try await Task.sleep(for: .milliseconds(100)) }
            return text
        }, onProgress: { saved.append(($0, $1)) })
        reader.configure(.init(width: 350, height: 680, fontSize: 19, lineSpacing: 9))
        await reader.loadTask?.value
        #expect(reader.pageIndex == 0)
        reader.turn(-1)
        #expect(reader.message == "已到全书开头")
        reader.turn(1)
        let anchor = reader.anchor
        #expect(anchor > 0)
        reader.configure(.init(width: 650, height: 260, fontSize: 30, lineSpacing: 20))
        await reader.loadTask?.value
        #expect(reader.anchor == anchor)
        #expect(reader.pagination?.page(containing: anchor) == reader.pageIndex)
        reader.goToChapter(1)
        await reader.loadTask?.value
        reader.turn(-1)
        await reader.loadTask?.value
        #expect(reader.chapterIndex == 0)
        #expect(reader.pageIndex == (reader.pagination?.ranges.count ?? 0) - 1)
        reader.turn(1)
        await reader.loadTask?.value
        #expect(reader.chapterIndex == 1 && reader.pageIndex == 0 && reader.anchor == 0)
        reader.goToChapter(4)
        reader.goToChapter(12)
        await reader.loadTask?.value
        try await Task.sleep(for: .milliseconds(150))
        #expect(reader.chapterIndex == 12 && reader.pageIndex == 0)
        #expect(saved.last?.0 == 12)
        #expect(reader.cachedChapterCount <= 3)
        reader.goToChapter(19)
        await reader.loadTask?.value
        for _ in 0..<(reader.pagination?.ranges.count ?? 0) { reader.turn(1) }
        #expect(reader.chapterIndex == 19)
        #expect(reader.message == "已到全书末尾")
        reader.stop()
        let reopened = ReadingSession(chapterCount: 20, startIndex: 1, startOffset: anchor)
        reopened.start(load: { _ in text }, onProgress: { _, _ in })
        reopened.configure(.init(width: 350, height: 680, fontSize: 19, lineSpacing: 9))
        await reopened.loadTask?.value
        #expect(reopened.pageIndex == 1)
        reopened.stop()
    }

    @Test("当前章节失败可重试，预加载失败不影响正文")
    @MainActor func retry() async {
        var attempts = 0
        let reader = ReadingSession(chapterCount: 2, startIndex: 0)
        reader.start(load: { index in
            attempts += 1
            if attempts == 1 || index == 1 { throw URLError(.notConnectedToInternet) }
            return "恢复后的正文"
        }, onProgress: { _, _ in })
        reader.configure(.init(width: 300, height: 500, fontSize: 19, lineSpacing: 9))
        await reader.loadTask?.value
        #expect(reader.errorMessage != nil)
        reader.retry()
        await reader.loadTask?.value
        #expect(reader.errorMessage == nil)
        #expect(reader.pagination?.text == "恢复后的正文")
        reader.stop()
    }
}
