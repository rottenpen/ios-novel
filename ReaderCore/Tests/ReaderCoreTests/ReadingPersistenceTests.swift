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

    @Test("冷启动续看取最近一本，缺目录或未读过时不续看")
    func resume() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = BookshelfRepository(directory: directory)

        func makeChapters(_ count: Int, prefix: String) -> [BookChapter] {
            (0..<count).map { index in
                var chapter = BookChapter()
                chapter.index = index
                chapter.title = "\(prefix)第\(index + 1)章"
                chapter.url = "https://example.invalid/\(prefix)/\(index)"
                return chapter
            }
        }

        // 仅加入书架、从未阅读：不应触发续看
        var idle = Book()
        idle.bookUrl = "https://example.invalid/idle"
        idle.name = "没读过的书"
        shelf.add(idle)
        shelf.saveChapters(makeChapters(3, prefix: "A"), for: idle.bookUrl)
        shelf.flush()
        #expect(shelf.resumeCandidate() == nil)

        // 读过第 2 章偏移 250：应成为续看目标
        var read = Book()
        read.bookUrl = "https://example.invalid/read"
        read.name = "读过的书"
        let readChapters = makeChapters(5, prefix: "B")
        _ = shelf.beginReading(book: read, chapters: readChapters, chapterIndex: 1)
        shelf.updateProgress(bookUrl: read.bookUrl, chapterIndex: 1,
                             chapterTitle: readChapters[1].title, position: 250)
        shelf.flush()
        let target = try #require(shelf.resumeCandidate())
        #expect(target.book.bookUrl == read.bookUrl)
        #expect(target.chapterIndex == 1)
        #expect(target.position == 250)
        #expect(target.chapters.count == 5)

        // 另一本书后读，续看应切到更晚的那本
        var latest = Book()
        latest.bookUrl = "https://example.invalid/latest"
        latest.name = "最近读的书"
        let latestChapters = makeChapters(4, prefix: "C")
        _ = shelf.beginReading(book: latest, chapters: latestChapters, chapterIndex: 3)
        shelf.flush()
        #expect(shelf.resumeCandidate()?.book.bookUrl == latest.bookUrl)

        // 重启后仍能恢复同一目标
        let restarted = BookshelfRepository(directory: directory)
        #expect(restarted.resumeCandidate()?.book.bookUrl == latest.bookUrl)

        // 最近一本缺目录缓存时不续看，也不改为打开另一本旧书
        restarted.saveChapters([], for: latest.bookUrl)
        restarted.flush()
        #expect(restarted.resumeCandidate() == nil)

        // 目录恢复后重新可续看；章节数收缩时索引夹到合法范围，不越界
        restarted.saveChapters(makeChapters(1, prefix: "C"), for: latest.bookUrl)
        restarted.flush()
        let clamped = try #require(restarted.resumeCandidate())
        #expect(clamped.book.bookUrl == latest.bookUrl)
        #expect(clamped.chapterIndex == 0)

        // 最近一本被移出书架后，续看回落到上一本读过的书
        restarted.remove(latest.bookUrl)
        restarted.flush()
        #expect(restarted.resumeCandidate()?.book.bookUrl == read.bookUrl)

        // 移除全部书后不再续看
        restarted.remove(read.bookUrl)
        restarted.remove(idle.bookUrl)
        restarted.flush()
        #expect(restarted.resumeCandidate() == nil)
    }
}
