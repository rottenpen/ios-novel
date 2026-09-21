// Swift 实现及修改：Yuedu 项目，2026-09-20。
// 来源与许可见仓库根目录 THIRD_PARTY_NOTICES.md（GPL-3.0）。
import Foundation
import Combine

/// 整本 / 指定范围的正文离线下载。
///
/// 行为要点：
/// - 并发抓取，限制并发度（默认 4），与书架批量检查更新保持一致，避免同时打开过多连接
/// - 已缓存章节直接跳过，不重复请求；断点续传即「再点一次下载」
/// - 单章失败不中断整体，累计失败数并记录可重试的章节
/// - 支持取消；取消后已下载的部分保留
/// - 卷标题（`isVolume`）无正文，按已完成计，不发请求
@MainActor
public final class DownloadManager: ObservableObject {
    public static let shared = DownloadManager()

    /// 当前下载任务的状态快照
    public struct Progress: Sendable, Equatable {
        /// 需要下载的章节总数（已排除本来就有缓存的）
        public var total: Int
        /// 已成功完成数
        public var completed: Int
        /// 失败数
        public var failed: Int
        /// 本次开始前就已缓存、被跳过的章节数
        public var skipped: Int

        public var handled: Int { completed + failed }

        public var fraction: Double {
            guard total > 0 else { return 1 }
            return min(1, Double(handled) / Double(total))
        }

        public var isFinished: Bool { handled >= total }
    }

    /// 正在下载的书，nil 表示空闲
    @Published public private(set) var activeBookUrl: String?
    @Published public private(set) var progress = Progress(total: 0, completed: 0, failed: 0, skipped: 0)
    /// 失败的章节下标，可用于重试
    @Published public private(set) var failedChapters: [Int] = []
    /// 面向用户的结果提示，完成或取消后写入
    @Published public var message: String?

    private var task: Task<Void, Never>?
    private var generation = UUID()

    /// 单章抓取实现。默认走书源，测试可注入以避免依赖真实网络。
    /// 约定：抛错即表示该章失败，由调用方累计并允许重试。
    public typealias Fetcher = @Sendable (BookSource, Book, BookChapter, String?) async throws -> String

    private let fetcher: Fetcher

    public init(fetcher: @escaping Fetcher = { source, book, chapter, next in
        try await WebBook.content(source: source, book: book, chapter: chapter, nextChapterUrl: next)
    }) {
        self.fetcher = fetcher
    }

    public var isDownloading: Bool { activeBookUrl != nil }

    /// 是否正在下载指定的书
    public func isDownloading(bookUrl: String) -> Bool {
        activeBookUrl == bookUrl
    }

    /// 开始下载。
    ///
    /// - Parameters:
    ///   - range: 需要下载的章节下标集合；传 nil 表示整本。
    ///   - maxConcurrent: 并发抓取数，最小 1。
    /// 已有任务在运行时直接忽略，由调用方先取消，避免两本书同时抢占连接。
    public func start(
        book: Book,
        chapters: [BookChapter],
        source: BookSource,
        shelf: BookshelfRepository,
        range: [Int]? = nil,
        maxConcurrent: Int = 4
    ) {
        guard !isDownloading else {
            message = "已有下载任务在进行，请先停止"
            return
        }
        guard !chapters.isEmpty else {
            message = "目录为空，无法下载"
            return
        }

        let targets = (range ?? Array(chapters.indices)).filter { chapters.indices.contains($0) }
        // 已缓存的不再重复请求，这样「继续下载」天然就是断点续传
        let pending = targets.filter { !shelf.hasContent(bookUrl: book.bookUrl, chapterIndex: $0) }
        let skipped = targets.count - pending.count

        guard !pending.isEmpty else {
            progress = Progress(total: 0, completed: 0, failed: 0, skipped: skipped)
            message = skipped > 0 ? "已全部缓存，无需下载" : "没有可下载的章节"
            return
        }

        activeBookUrl = book.bookUrl
        progress = Progress(total: pending.count, completed: 0, failed: 0, skipped: skipped)
        failedChapters = []
        generation = UUID()
        let token = generation

        task = Task { [weak self] in
            await self?.run(
                book: book, chapters: chapters, source: source, shelf: shelf,
                pending: pending, maxConcurrent: max(1, maxConcurrent), token: token
            )
        }
    }

    /// 停止当前下载，已完成的部分保留
    public func cancel() {
        guard isDownloading else { return }
        generation = UUID()
        task?.cancel()
        task = nil
        let done = progress.completed
        activeBookUrl = nil
        message = done > 0 ? "已停止下载，已缓存 \(done) 章" : "已停止下载"
    }

    /// 重试上一次失败的章节
    public func retryFailed(
        book: Book, chapters: [BookChapter], source: BookSource,
        shelf: BookshelfRepository, maxConcurrent: Int = 4
    ) {
        let targets = failedChapters
        guard !targets.isEmpty else { return }
        start(book: book, chapters: chapters, source: source, shelf: shelf,
              range: targets, maxConcurrent: maxConcurrent)
    }

    private func run(
        book: Book, chapters: [BookChapter], source: BookSource,
        shelf: BookshelfRepository, pending: [Int], maxConcurrent: Int, token: UUID
    ) async {
        await withTaskGroup(of: (Int, String?).self) { group in
            var iterator = pending.makeIterator()
            var running = 0

            func addNext() -> Bool {
                guard let index = iterator.next() else { return false }
                let chapter = chapters[index]
                let next = chapters[safeIndex: index + 1]?.url
                let fetch = fetcher
                group.addTask {
                    // 卷标题没有正文，直接落标题，避免无谓请求
                    if chapter.isVolume, chapter.url.hasPrefix(chapter.title) {
                        return (index, chapter.title)
                    }
                    do {
                        let text = try await fetch(source, book, chapter, next)
                        try Task.checkCancellation()
                        return (index, text)
                    } catch {
                        // 单章失败不抛出，避免中断整个 group
                        return (index, nil)
                    }
                }
                return true
            }

            while running < maxConcurrent, addNext() { running += 1 }

            while let (index, text) = await group.next() {
                // 任务已被取消或替换时立即收尾，不再写入过期结果
                if Task.isCancelled || generation != token {
                    group.cancelAll()
                    return
                }
                if let text {
                    shelf.saveContent(text, bookUrl: book.bookUrl, chapterIndex: index)
                    progress.completed += 1
                } else {
                    progress.failed += 1
                    failedChapters.append(index)
                }
                _ = addNext()
            }
        }

        guard generation == token, !Task.isCancelled else { return }
        // 落盘后再报完成，避免用户立即离线阅读时读不到
        shelf.flush()
        activeBookUrl = nil
        task = nil
        failedChapters.sort()
        message = Self.summary(progress)
    }

    private static func summary(_ progress: Progress) -> String {
        var parts: [String] = []
        if progress.completed > 0 { parts.append("新缓存 \(progress.completed) 章") }
        if progress.skipped > 0 { parts.append("跳过已缓存 \(progress.skipped) 章") }
        if progress.failed > 0 { parts.append("失败 \(progress.failed) 章") }
        return parts.isEmpty ? "下载完成" : parts.joined(separator: "，")
    }
}

private extension Array {
    /// 安全下标，越界返回 nil；核心库内部使用，避免与 App 层扩展重名冲突
    subscript(safeIndex index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
