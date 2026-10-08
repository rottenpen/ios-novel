import XCTest
@testable import ReaderCore

@MainActor
final class BookmarkTests: XCTestCase {
    private var repo: BookshelfRepository!
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bm-tests-\(UUID().uuidString)", isDirectory: true)
        repo = BookshelfRepository(fileName: "shelf.json", directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAddAndList() {
        let url = "https://example.com/book/1"
        repo.addBookmark(bookUrl: url, chapterIndex: 3, chapterTitle: "第三章",
                         position: 120, excerpt: "这是摘录")
        let list = repo.bookmarks(for: url)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.chapterTitle, "第三章")
        XCTAssertEqual(list.first?.position, 120)
        XCTAssertEqual(list.first?.excerpt, "这是摘录")
    }

    func testAddDuplicateDeduplicates() {
        let url = "https://example.com/book/2"
        repo.addBookmark(bookUrl: url, chapterIndex: 0, chapterTitle: "第一章",
                         position: 50, excerpt: "a")
        repo.addBookmark(bookUrl: url, chapterIndex: 0, chapterTitle: "第一章",
                         position: 50, excerpt: "b")
        XCTAssertEqual(repo.bookmarks(for: url).count, 1)
    }

    func testRemove() {
        let url = "https://example.com/book/3"
        let bm = repo.addBookmark(bookUrl: url, chapterIndex: 1, chapterTitle: "第二章",
                                  position: 10, excerpt: "x")
        repo.removeBookmark(bookUrl: url, id: bm.id)
        XCTAssertTrue(repo.bookmarks(for: url).isEmpty)
    }

    func testHasBookmark() {
        let url = "https://example.com/book/4"
        repo.addBookmark(bookUrl: url, chapterIndex: 5, chapterTitle: "第五章",
                         position: 99, excerpt: "y")
        XCTAssertTrue(repo.hasBookmark(bookUrl: url, chapterIndex: 5, position: 99))
        XCTAssertFalse(repo.hasBookmark(bookUrl: url, chapterIndex: 5, position: 100))
    }

    func testClearCacheKeepsBookmarks() throws {
        let url = "https://example.com/book/5"
        repo.addBookmark(bookUrl: url, chapterIndex: 2, chapterTitle: "第二章",
                         position: 30, excerpt: "z")
        // 先写一点正文缓存
        repo.saveContent("正文内容", bookUrl: url, chapterIndex: 2)
        repo.flush()
        repo.clearCache(for: url)
        repo.flush()
        XCTAssertEqual(repo.bookmarks(for: url).count, 1, "清缓存不应删书签")
    }
}
