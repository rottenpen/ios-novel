// Swift 实现及修改：Yuedu 项目，2026-09-14。
// 来源与许可见仓库根目录 THIRD_PARTY_NOTICES.md（GPL-3.0）。
import Foundation
import Combine

/// 书架条目：书籍 + 阅读进度
public struct ShelfBook: Codable, Sendable, Identifiable, Hashable {
    public var book: Book
    /// 已缓存的章节总数，用于书架显示「有更新」
    public var lastKnownChapterCount: Int
    public var addedAt: Date
    public var lastReadAt: Date?

    public init(book: Book, lastKnownChapterCount: Int = 0, addedAt: Date = Date()) {
        self.book = book
        self.lastKnownChapterCount = lastKnownChapterCount
        self.addedAt = addedAt
    }

    public var id: String { book.bookUrl }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(book.bookUrl)
    }

    public static func == (lhs: ShelfBook, rhs: ShelfBook) -> Bool {
        lhs.book.bookUrl == rhs.book.bookUrl
    }

    /// 阅读进度百分比（0~1）
    public var progress: Double {
        guard book.totalChapterNum > 0 else { return 0 }
        return min(1, Double(book.durChapterIndex + 1) / Double(book.totalChapterNum))
    }

    public var hasUpdate: Bool {
        book.totalChapterNum > lastKnownChapterCount && lastKnownChapterCount > 0
    }
}

/// 书架仓库：书籍、章节目录、正文缓存与阅读进度的持久化。
///
/// 存储分层：
/// - 书架元数据（书籍 + 进度）：单个 JSON，原子写入
/// - 章节目录：按书 URL 哈希分文件，避免单文件过大
/// - 正文：按章节分文件缓存，支持离线阅读
@MainActor
public final class BookshelfRepository: ObservableObject {
    public static let shared = BookshelfRepository()

    @Published public private(set) var books: [ShelfBook] = []

    private let fileURL: URL
    private let cacheDirectory: URL
    private let queue = DispatchQueue(label: "com.yuedu.shelf-repo", qos: .utility)

    public init(fileName: String = "bookshelf.json", directory: URL? = nil) {
        let root = directory ?? AppPaths.documents
        self.fileURL = root.appendingPathComponent(fileName)
        self.cacheDirectory = root.appendingPathComponent("content", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - 书架

    public func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([ShelfBook].self, from: data) else {
            books = []
            return
        }
        books = list.sorted { ($0.lastReadAt ?? $0.addedAt) > ($1.lastReadAt ?? $1.addedAt) }
    }

    public func save() {
        let snapshot = books
        let url = fileURL
        queue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                JSLog.shared.append("书架进度保存失败，请检查可用存储空间")
            }
        }
    }

    /// 退出阅读或切入后台前，确保已排队的进度与缓存写入完成。
    public func flush() { queue.sync {} }

    public struct ReadingPosition: Sendable {
        public let chapter: Int
        public let offset: Int
    }

    public func beginReading(book: Book, chapters: [BookChapter], chapterIndex: Int? = nil) -> ReadingPosition? {
        guard !chapters.isEmpty else { return nil }
        var target = book
        target.totalChapterNum = chapters.count
        if contains(book.bookUrl) { update(target) } else { add(target) }
        saveChapters(chapters, for: book.bookUrl)
        let saved = shelfBook(for: book.bookUrl)?.book
        let index = max(0, min(chapterIndex ?? saved?.durChapterIndex ?? 0, chapters.count - 1))
        let offset = chapterIndex == nil && index == saved?.durChapterIndex ? max(0, saved?.durChapterPos ?? 0) : 0
        updateProgress(bookUrl: book.bookUrl, chapterIndex: index, chapterTitle: chapters[index].title, position: offset)
        return ReadingPosition(chapter: index, offset: offset)
    }

    public func contains(_ bookUrl: String) -> Bool {
        books.contains { $0.book.bookUrl == bookUrl }
    }

    public func shelfBook(for bookUrl: String) -> ShelfBook? {
        books.first { $0.book.bookUrl == bookUrl }
    }

    public func add(_ book: Book) {
        guard !contains(book.bookUrl) else {
            update(book)
            return
        }
        var entry = ShelfBook(book: book)
        entry.lastKnownChapterCount = book.totalChapterNum
        books.insert(entry, at: 0)
        save()
    }

    public func remove(_ bookUrl: String) {
        books.removeAll { $0.book.bookUrl == bookUrl }
        // 连带清理该书的目录与正文缓存，避免残留占用空间
        clearCache(for: bookUrl)
        save()
    }

    public func remove(at offsets: IndexSet) {
        let urls = offsets.map { books[$0].book.bookUrl }
        for url in urls { clearCache(for: url) }
        books.removeAll { urls.contains($0.book.bookUrl) }
        save()
    }

    /// 更新书籍信息（保留已有阅读进度）
    public func update(_ book: Book) {
        guard let index = books.firstIndex(where: { $0.book.bookUrl == book.bookUrl }) else {
            return
        }
        var merged = book
        // 进度以本地为准，避免详情刷新把进度重置
        merged.durChapterIndex = books[index].book.durChapterIndex
        merged.durChapterPos = books[index].book.durChapterPos
        merged.durChapterTitle = books[index].book.durChapterTitle
        books[index].book = merged
        save()
    }

    /// 记录阅读进度
    public func updateProgress(
        bookUrl: String,
        chapterIndex: Int,
        chapterTitle: String?,
        position: Int = 0
    ) {
        guard let index = books.firstIndex(where: { $0.book.bookUrl == bookUrl }) else { return }
        books[index].book.durChapterIndex = chapterIndex
        books[index].book.durChapterPos = position
        books[index].book.durChapterTitle = chapterTitle
        books[index].book.durChapterTime = Date().timeIntervalSince1970
        books[index].lastReadAt = Date()
        save()
    }

    /// 目录刷新后同步章节数
    public func updateChapterCount(bookUrl: String, count: Int) {
        guard let index = books.firstIndex(where: { $0.book.bookUrl == bookUrl }) else { return }
        books[index].book.totalChapterNum = count
        books[index].book.lastCheckTime = Date().timeIntervalSince1970
        save()
    }

    /// 标记已读到最新（清除更新红点）
    public func markUpdateSeen(bookUrl: String) {
        guard let index = books.firstIndex(where: { $0.book.bookUrl == bookUrl }) else { return }
        books[index].lastKnownChapterCount = books[index].book.totalChapterNum
        save()
    }

    // MARK: - 章节目录缓存

    private func tocURL(for bookUrl: String) -> URL {
        cacheDirectory
            .appendingPathComponent("toc_\(Self.hash(bookUrl)).json")
    }

    public func saveChapters(_ chapters: [BookChapter], for bookUrl: String) {
        let url = tocURL(for: bookUrl)
        queue.async {
            guard let data = try? JSONEncoder().encode(chapters) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    public func loadChapters(for bookUrl: String) -> [BookChapter] {
        flush()
        guard let data = try? Data(contentsOf: tocURL(for: bookUrl)),
              let list = try? JSONDecoder().decode([BookChapter].self, from: data) else {
            return []
        }
        return list
    }

    // MARK: - 正文缓存

    private func contentURL(bookUrl: String, chapterIndex: Int) -> URL {
        cacheDirectory
            .appendingPathComponent("c_\(Self.hash(bookUrl))_\(chapterIndex).txt")
    }

    public func saveContent(_ text: String, bookUrl: String, chapterIndex: Int) {
        let url = contentURL(bookUrl: bookUrl, chapterIndex: chapterIndex)
        queue.async {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    public func loadContent(bookUrl: String, chapterIndex: Int) -> String? {
        flush()
        return try? String(contentsOf: contentURL(bookUrl: bookUrl, chapterIndex: chapterIndex),
                    encoding: .utf8)
    }

    public func hasContent(bookUrl: String, chapterIndex: Int) -> Bool {
        FileManager.default.fileExists(
            atPath: contentURL(bookUrl: bookUrl, chapterIndex: chapterIndex).path
        )
    }

    /// 清理指定书籍的全部缓存
    public func clearCache(for bookUrl: String) {
        let prefix = "c_\(Self.hash(bookUrl))_"
        let tocName = "toc_\(Self.hash(bookUrl)).json"
        let dir = cacheDirectory
        queue.async {
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for name in items where name.hasPrefix(prefix) || name == tocName {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    /// 缓存占用大小（字节）
    public func cacheSize() -> Int64 {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return items.reduce(into: Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
    }

    public func clearAllCache() {
        let dir = cacheDirectory
        queue.async {
            let fm = FileManager.default
            guard let items = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for name in items {
                try? fm.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }

    /// 文件名安全的稳定哈希（避免 URL 中的特殊字符）
    private static func hash(_ text: String) -> String {
        var hasher: UInt64 = 5381
        for byte in text.utf8 {
            hasher = (hasher << 5) &+ hasher &+ UInt64(byte)
        }
        return String(hasher, radix: 36)
    }
}
