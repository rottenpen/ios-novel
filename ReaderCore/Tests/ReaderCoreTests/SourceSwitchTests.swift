import Foundation
import Testing
@testable import ReaderCore

@Suite("换源与章节定位")
struct SourceSwitchTests {
    private func chapters(_ titles: [String]) -> [BookChapter] {
        titles.enumerated().map { index, title in
            var chapter = BookChapter()
            chapter.title = title
            chapter.index = index
            chapter.url = "https://new.example/\(index)"
            return chapter
        }
    }

    @Test("标题匹配跨目录位移、序号格式和附加说明")
    func match() throws {
        var list = chapters(["作品相关", "第一章 开始", "第四百零一章 露头就往死里打！", "第四百零二章 后续"])
        list[0].isVolume = true
        let match = try #require(ChapterMatcher.match(title: "第 401 章 露头就往死里打（求月票）", index: 400, chapters: list))
        #expect(match.index == 2 && match.matchedTitle)
        let fallback = try #require(ChapterMatcher.match(title: "未知章节", index: 0, chapters: list))
        #expect(fallback.index == 1 && !fallback.matchedTitle)
        #expect(ChapterMatcher.match(title: "", index: 0, chapters: []) == nil)
        #expect(ChapterMatcher.sameBookName("《普罗之主》", "普罗之主"))
        #expect(!ChapterMatcher.sameBookName("普罗之主", "普罗之主番外"))
    }

    @Test("切换后保存新目录与正文，重置偏移并合并书架重复项", arguments: [false, true])
    @MainActor func replace(sameURL: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = BookshelfRepository(directory: directory)
        var old = Book()
        old.bookUrl = "https://old.example/book"
        old.origin = "old"
        old.name = "测试书"
        old.customTag = "我的分组"
        old.durChapterPos = 130
        shelf.add(old)
        let addedAt = shelf.books[0].addedAt
        var new = old
        new.bookUrl = sameURL ? old.bookUrl : "https://new.example/book"
        new.origin = "new"
        new.customTag = nil
        if !sameURL { shelf.add(new) }
        shelf.saveContent("旧源短正文", bookUrl: old.bookUrl, chapterIndex: 1)
        shelf.saveContent("新源过期缓存", bookUrl: new.bookUrl, chapterIndex: 0)
        let catalog = chapters(["第一章 开始", "第二章 继续"])
        #expect(shelf.replaceSource(bookUrl: old.bookUrl, with: new, chapters: [], chapterIndex: 1, content: "正文") == nil)
        #expect(shelf.shelfBook(for: old.bookUrl)?.book.origin == "old")
        #expect(shelf.replaceSource(bookUrl: old.bookUrl, with: new, chapters: catalog, chapterIndex: 1, content: " \n") == nil)
        _ = try #require(shelf.replaceSource(bookUrl: old.bookUrl, with: new, chapters: catalog, chapterIndex: 1, content: "完整的新源正文"))
        let restored = BookshelfRepository(directory: directory)
        #expect(restored.books.count == 1)
        let saved = try #require(restored.books.first)
        #expect(saved.book.origin == "new")
        #expect(saved.book.durChapterIndex == 1 && saved.book.durChapterPos == 0)
        #expect(saved.book.customTag == "我的分组" && saved.addedAt == addedAt)
        #expect(restored.loadChapters(for: new.bookUrl) == catalog)
        #expect(restored.loadContent(bookUrl: new.bookUrl, chapterIndex: 1) == "完整的新源正文")
        #expect(restored.loadContent(bookUrl: new.bookUrl, chapterIndex: 0) == nil)
        if !sameURL { #expect(restored.loadContent(bookUrl: old.bookUrl, chapterIndex: 1) == nil) }
    }
}
