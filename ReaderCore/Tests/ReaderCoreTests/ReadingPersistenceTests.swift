import Foundation
import Testing
@testable import ReaderCore

@Suite("阅读入口与持久化")
@MainActor
struct ReadingPersistenceTests {
    @Test("目录阅读自动入架，恢复偏移并保留旧数据格式")
    func restore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = BookshelfRepository(directory: directory)
        var book = Book()
        book.bookUrl = "https://example.invalid/book"
        book.name = "测试书"
        let chapters = (0..<3).map { index in
            var chapter = BookChapter()
            chapter.index = index
            chapter.title = "第\(index + 1)章"
            chapter.url = "https://example.invalid/\(index)"
            return chapter
        }
        let initial = try #require(shelf.beginReading(book: book, chapters: chapters, chapterIndex: 1))
        #expect(initial.chapter == 1 && initial.offset == 0)
        #expect(shelf.contains(book.bookUrl))
        shelf.updateProgress(bookUrl: book.bookUrl, chapterIndex: 1, chapterTitle: chapters[1].title, position: 250)
        shelf.saveContent("缓存正文", bookUrl: book.bookUrl, chapterIndex: 1)
        shelf.flush()
        let restored = BookshelfRepository(directory: directory)
        let continued = try #require(restored.beginReading(book: book, chapters: chapters))
        #expect(continued.chapter == 1 && continued.offset == 250)
        #expect(restored.loadChapters(for: book.bookUrl).count == 3)
        #expect(restored.loadContent(bookUrl: book.bookUrl, chapterIndex: 1) == "缓存正文")
        let jump = try #require(restored.beginReading(book: book, chapters: chapters, chapterIndex: 1))
        #expect(jump.offset == 0)
        #expect(restored.beginReading(book: book, chapters: []) == nil)
        restored.saveChapters(Array(chapters.prefix(2)), for: book.bookUrl)
        #expect(restored.loadChapters(for: book.bookUrl).count == 2)
        restored.flush()
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("bookshelf.json"))) as? [[String: Any]]
        let saved = json?.first?["book"] as? [String: Any]
        #expect(saved?["durChapterIndex"] as? Int == 1)
        #expect(saved?["durChapterPos"] as? Int == 0)
    }
}
