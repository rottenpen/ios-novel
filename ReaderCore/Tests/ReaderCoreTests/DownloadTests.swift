import Foundation
import Testing
@testable import ReaderCore

@Suite("整本下载")
@MainActor
struct DownloadTests {

    private func makeBook(_ url: String = "https://example.invalid/book") -> Book {
        var book = Book()
        book.bookUrl = url
        book.name = "测试书"
        book.origin = "https://example.invalid"
        return book
    }

    private func makeChapters(_ count: Int) -> [BookChapter] {
        (0..<count).map { index in
            var chapter = BookChapter()
            chapter.index = index
            chapter.title = "第\(index + 1)章"
            chapter.url = "https://example.invalid/c/\(index)"
            return chapter
        }
    }

    private func makeSource() -> BookSource {
        var source = BookSource()
        source.bookSourceUrl = "https://example.invalid"
        source.bookSourceName = "测试源"
        return source
    }

    /// 等待下载结束，避免依赖固定 sleep 时长
    private func waitUntilIdle(_ manager: DownloadManager, limit: Int = 400) async {
        for _ in 0..<limit {
            if !manager.isDownloading { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test("整本下载写入全部正文并汇报进度")
    func downloadAll() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = BookshelfRepository(directory: directory)
        let book = makeBook()
        let chapters = makeChapters(12)

        let manager = DownloadManager { _, _, chapter, _ in
            "正文-\(chapter.index)"
        }
        manager.start(book: book, chapters: chapters, source: makeSource(), shelf: shelf)
        #expect(manager.isDownloading)
        await waitUntilIdle(manager)

        #expect(manager.progress.completed == 12)
        #expect(manager.progress.failed == 0)
        #expect(manager.progress.skipped == 0)
        #expect(manager.progress.isFinished)
        #expect(manager.failedChapters.isEmpty)
        #expect(manager.isDownloading == false)
        for index in 0..<12 {
            #expect(shelf.loadContent(bookUrl: book.bookUrl, chapterIndex: index) == "正文-\(index)")
        }
    }

    @Test("已缓存章节被跳过，不重复请求")
    func skipCached() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = BookshelfRepository(directory: directory)
        let book = makeBook()
        let chapters = makeChapters(6)
        // 预置 3 章缓存
        for index in [0, 2, 4] {
            shelf.saveContent("旧正文-\(index)", bookUrl: book.bookUrl, chapterIndex: index)
        }
        shelf.flush()

        let requested = Mutex<[Int]>([])
        let manager = DownloadManager { _, _, chapter, _ in
            requested.withLock { $0.append(chapter.index) }
            return "新正文-\(chapter.index)"
        }
        manager.start(book: book, chapters: chapters, source: makeSource(), shelf: shelf)
        await waitUntilIdle(manager)

        #expect(manager.progress.skipped == 3)
        #expect(manager.progress.completed == 3)
        #expect(requested.withLock { $0.sorted() } == [1, 3, 5])
        // 已缓存内容不被覆盖
        #expect(shelf.loadContent(bookUrl: book.bookUrl, chapterIndex: 0) == "旧正文-0")
        #expect(shelf.loadContent(bookUrl: book.bookUrl, chapterIndex: 1) == "新正文-1")
    }

    @Test("单章失败不中断整体，可重试失败章节")
    func failureAndRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = BookshelfRepository(directory: directory)
        let book = makeBook()
        let chapters = makeChapters(8)

        struct Boom: Error {}
        let shouldFail = Mutex<Bool>(true)
        let manager = DownloadManager { _, _, chapter, _ in
            // 第一轮让 2、5 失败，重试时全部成功
            if shouldFail.withLock({ $0 }), chapter.index == 2 || chapter.index == 5 {
                throw Boom()
            }
            return "正文-\(chapter.index)"
        }

        manager.start(book: book, chapters: chapters, source: makeSource(), shelf: shelf)
        await waitUntilIdle(manager)

        #expect(manager.progress.completed == 6)
        #expect(manager.progress.failed == 2)
        #expect(manager.failedChapters == [2, 5])
        #expect(shelf.loadContent(bookUrl: book.bookUrl, chapterIndex: 2) == nil)

        // 重试
        shouldFail.withLock { $0 = false }
        manager.retryFailed(book: book, chapters: chapters, source: makeSource(), shelf: shelf)
        await waitUntilIdle(manager)

        #expect(manager.progress.completed == 2)
        #expect(manager.progress.failed == 0)
        #expect(manager.failedChapters.isEmpty)
        #expect(shelf.loadContent(bookUrl: book.bookUrl, chapterIndex: 2) == "正文-2")
        #expect(shelf.loadContent(bookUrl: book.bookUrl, chapterIndex: 5) == "正文-5")
    }

    @Test("取消后停止下载，已完成部分保留")
    func cancelKeepsFinished() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = BookshelfRepository(directory: directory)
        let book = makeBook()
        let chapters = makeChapters(40)

        let manager = DownloadManager { _, _, chapter, _ in
            // 放慢速度，确保取消时仍有未完成任务
            try? await Task.sleep(nanoseconds: 30_000_000)
            return "正文-\(chapter.index)"
        }
        manager.start(book: book, chapters: chapters, source: makeSource(), shelf: shelf, maxConcurrent: 2)
        try? await Task.sleep(nanoseconds: 120_000_000)
        let doneBefore = manager.progress.completed
        manager.cancel()

        #expect(manager.isDownloading == false)
        #expect(doneBefore < 40)
        shelf.flush()
        // 取消前已写入的仍可读取
        if doneBefore > 0 {
            #expect(shelf.loadContent(bookUrl: book.bookUrl, chapterIndex: 0) != nil)
        }
        // 取消后进度不再增长
        let settled = manager.progress.completed
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(manager.progress.completed == settled)
    }

    @Test("指定范围下载与边界处理")
    func rangeAndGuards() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = BookshelfRepository(directory: directory)
        let book = makeBook()
        let chapters = makeChapters(10)
        let manager = DownloadManager { _, _, chapter, _ in "正文-\(chapter.index)" }

        // 空目录不启动
        manager.start(book: book, chapters: [], source: makeSource(), shelf: shelf)
        #expect(manager.isDownloading == false)

        // 越界下标被过滤，只下载 7、8、9
        manager.start(book: book, chapters: chapters, source: makeSource(), shelf: shelf, range: [7, 8, 9, 99, -1])
        await waitUntilIdle(manager)
        #expect(manager.progress.completed == 3)
        #expect(shelf.loadContent(bookUrl: book.bookUrl, chapterIndex: 7) == "正文-7")
        #expect(shelf.loadContent(bookUrl: book.bookUrl, chapterIndex: 6) == nil)

        // 全部已缓存时不再下载
        manager.start(book: book, chapters: chapters, source: makeSource(), shelf: shelf, range: [7, 8, 9])
        #expect(manager.isDownloading == false)
        #expect(manager.progress.skipped == 3)
        #expect(manager.message == "已全部缓存，无需下载")
    }

    @Test("卷标题不发请求，直接落标题")
    func volumeChapters() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = BookshelfRepository(directory: directory)
        let book = makeBook()
        var chapters = makeChapters(3)
        chapters[1].isVolume = true
        chapters[1].title = "第二卷"
        chapters[1].url = "第二卷"

        let requested = Mutex<[Int]>([])
        let manager = DownloadManager { _, _, chapter, _ in
            requested.withLock { $0.append(chapter.index) }
            return "正文-\(chapter.index)"
        }
        manager.start(book: book, chapters: chapters, source: makeSource(), shelf: shelf)
        await waitUntilIdle(manager)

        #expect(manager.progress.completed == 3)
        // 卷标题没有发起网络请求
        #expect(requested.withLock { $0.sorted() } == [0, 2])
        #expect(shelf.loadContent(bookUrl: book.bookUrl, chapterIndex: 1) == "第二卷")
    }

    @Test("批量查询已缓存章节下标")
    func cachedIndexes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = BookshelfRepository(directory: directory)
        let book = makeBook()
        let other = makeBook("https://example.invalid/other")

        #expect(shelf.cachedChapterIndexes(bookUrl: book.bookUrl).isEmpty)

        for index in [0, 3, 17, 250] {
            shelf.saveContent("正文", bookUrl: book.bookUrl, chapterIndex: index)
        }
        // 另一本书的缓存不能混入
        shelf.saveContent("别的书", bookUrl: other.bookUrl, chapterIndex: 5)
        // 目录缓存文件也不能被误认成正文
        shelf.saveChapters(makeChapters(3), for: book.bookUrl)
        shelf.flush()

        let cached = shelf.cachedChapterIndexes(bookUrl: book.bookUrl)
        #expect(cached == [0, 3, 17, 250])
        #expect(shelf.cachedChapterIndexes(bookUrl: other.bookUrl) == [5])
        // 与逐章查询结果一致
        for index in [0, 3, 17, 250] {
            #expect(shelf.hasContent(bookUrl: book.bookUrl, chapterIndex: index))
        }
        #expect(shelf.hasContent(bookUrl: book.bookUrl, chapterIndex: 1) == false)

        shelf.clearCache(for: book.bookUrl)
        shelf.flush()
        #expect(shelf.cachedChapterIndexes(bookUrl: book.bookUrl).isEmpty)
        #expect(shelf.cachedChapterIndexes(bookUrl: other.bookUrl) == [5])
    }

    @Test("已有任务时不并发启动第二本")
    func singleActiveTask() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = BookshelfRepository(directory: directory)
        let first = makeBook("https://example.invalid/a")
        let second = makeBook("https://example.invalid/b")
        let chapters = makeChapters(20)

        let manager = DownloadManager { _, _, chapter, _ in
            try? await Task.sleep(nanoseconds: 20_000_000)
            return "正文-\(chapter.index)"
        }
        manager.start(book: first, chapters: chapters, source: makeSource(), shelf: shelf, maxConcurrent: 2)
        #expect(manager.isDownloading(bookUrl: first.bookUrl))

        manager.start(book: second, chapters: chapters, source: makeSource(), shelf: shelf)
        // 第二本被拒绝，活动任务仍是第一本
        #expect(manager.isDownloading(bookUrl: first.bookUrl))
        #expect(manager.isDownloading(bookUrl: second.bookUrl) == false)
        #expect(manager.message == "已有下载任务在进行，请先停止")

        manager.cancel()
    }
}

/// 测试用的轻量互斥容器，供并发闭包安全累计调用记录
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    @discardableResult
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

@Suite("缓存大小与清理")
@MainActor
struct CacheSizeTests {
    @Test("cacheSize 反映写入，clearAllCache 清空全部书")
    func sizeAndClear() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = BookshelfRepository(directory: directory)

        #expect(shelf.cacheSize() == 0)

        // 写入两本书的正文
        for index in 0..<5 {
            shelf.saveContent(String(repeating: "字", count: 500), bookUrl: "book://a", chapterIndex: index)
        }
        for index in 0..<3 {
            shelf.saveContent(String(repeating: "文", count: 500), bookUrl: "book://b", chapterIndex: index)
        }
        shelf.flush()

        let size = await shelf.cacheSizeAsync()
        #expect(size > 0)
        #expect(size == shelf.cacheSize())  // 同步与异步结果一致

        // 清全部：两本书都被清掉
        shelf.clearAllCache()
        shelf.flush()
        #expect(shelf.cacheSize() == 0)
        #expect(shelf.cachedChapterIndexes(bookUrl: "book://a").isEmpty)
        #expect(shelf.cachedChapterIndexes(bookUrl: "book://b").isEmpty)
    }
}
