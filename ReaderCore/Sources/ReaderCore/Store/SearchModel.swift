// Swift 实现及修改：Yuedu 项目，2026-09-14。
// 来源与许可见仓库根目录 THIRD_PARTY_NOTICES.md（GPL-3.0）。
import Foundation
import Combine

/// 聚合搜索结果：同名同作者的书按书源聚合到一条
public struct AggregatedBook: Identifiable, Sendable, Hashable {
    public var name: String
    public var author: String
    public var coverUrl: String?
    public var intro: String?
    public var kind: String?
    public var wordCount: String?
    public var latestChapterTitle: String?
    /// 命中的书源结果，按书源顺序排列
    public var origins: [SearchBook]

    public var id: String { "\(name)|\(author)" }

    public var sourceCount: Int { origins.count }

    /// 默认使用第一个书源
    public var primary: SearchBook? { origins.first }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: AggregatedBook, rhs: AggregatedBook) -> Bool {
        lhs.id == rhs.id
    }
}

/// 多书源聚合搜索模型。
///
/// 行为要点：
/// - 并发搜索所有启用书源，限制并发度（默认 8）避免同时打开过多连接
/// - 结果流式合入，边搜边出，不等全部完成
/// - 单个书源失败不影响整体，只累计失败数
/// - 支持取消：切换关键词时中断上一轮
@MainActor
public final class SearchModel: ObservableObject {

    @Published public private(set) var results: [AggregatedBook] = []
    @Published public private(set) var isSearching = false
    @Published public private(set) var searchedCount = 0
    @Published public private(set) var totalCount = 0
    @Published public private(set) var failedCount = 0
    @Published public var keyword = ""

    private var task: Task<Void, Never>?
    private var generation = UUID()
    /// 聚合索引：key 为 "书名|作者"
    private var index: [String: Int] = [:]

    public init() {}

    public var progress: Double {
        guard totalCount > 0 else { return 0 }
        return Double(searchedCount) / Double(totalCount)
    }

    /// 开始搜索。重复调用会取消上一轮。
    public func search(keyword: String, sources: [BookSource], maxConcurrent: Int = 8) {
        cancel()
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)

        self.keyword = trimmed
        results = []
        index = [:]
        searchedCount = 0
        failedCount = 0
        totalCount = sources.count
        guard !trimmed.isEmpty, !sources.isEmpty else { totalCount = 0; return }
        isSearching = true
        let generation = self.generation

        task = Task { [weak self] in
            await self?.runSearch(keyword: trimmed, sources: sources, maxConcurrent: max(1, maxConcurrent), generation: generation)
        }
    }

    public func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isSearching = false
    }

    private func runSearch(keyword: String, sources: [BookSource], maxConcurrent: Int, generation: UUID) async {
        await withTaskGroup(of: (BookSource, [SearchBook]?).self) { group in
            var iterator = sources.makeIterator()
            var running = 0

            // 先填满并发窗口
            while running < maxConcurrent, let source = iterator.next() {
                group.addTask {
                    await Self.searchOne(source: source, keyword: keyword)
                }
                running += 1
            }

            while let (source, books) = await group.next() {
                if Task.isCancelled || self.generation != generation { group.cancelAll(); break }

                searchedCount += 1
                if let books {
                    merge(books, from: source)
                } else {
                    failedCount += 1
                }

                // 补充下一个任务，保持并发度
                if let next = iterator.next() {
                    group.addTask {
                        await Self.searchOne(source: next, keyword: keyword)
                    }
                }
            }
        }
        if self.generation == generation { isSearching = false; task = nil }
    }

    /// 单书源搜索，失败返回 nil（不抛出，避免中断整个 group）
    private static func searchOne(source: BookSource, keyword: String) async -> (BookSource, [SearchBook]?) {
        do {
            let books = try await WebBook.search(source: source, key: keyword)
            return (source, books)
        } catch {
            return (source, nil)
        }
    }

    /// 合并单书源结果到聚合列表
    private func merge(_ books: [SearchBook], from source: BookSource) {
        for book in books {
            // 过滤明显无效结果
            guard !book.name.isEmpty, !book.bookUrl.isEmpty else { continue }
            let key = "\(book.name)|\(book.author)"

            if let position = index[key] {
                // 已有该书，追加书源（避免同书源重复）
                if !results[position].origins.contains(where: { $0.origin == book.origin }) {
                    results[position].origins.append(book)
                }
                // 补齐先前缺失的字段
                if results[position].coverUrl == nil { results[position].coverUrl = book.coverUrl }
                if results[position].intro == nil { results[position].intro = book.intro }
                if results[position].latestChapterTitle == nil {
                    results[position].latestChapterTitle = book.latestChapterTitle
                }
            } else {
                let aggregated = AggregatedBook(
                    name: book.name,
                    author: book.author,
                    coverUrl: book.coverUrl,
                    intro: book.intro,
                    kind: book.kind,
                    wordCount: book.wordCount,
                    latestChapterTitle: book.latestChapterTitle,
                    origins: [book]
                )
                results.append(aggregated)
                index[key] = results.count - 1
            }
        }
        // 命中书源多的排前面（更可能是热门书 / 有效结果）
        sortResults()
    }

    private func sortResults() {
        // 保持索引与排序同步
        let keywordLower = keyword.lowercased()
        results.sort { lhs, rhs in
            // 书名精确匹配优先
            let lhsExact = lhs.name.lowercased() == keywordLower
            let rhsExact = rhs.name.lowercased() == keywordLower
            if lhsExact != rhsExact { return lhsExact }
            // 其次按命中书源数
            if lhs.sourceCount != rhs.sourceCount { return lhs.sourceCount > rhs.sourceCount }
            return lhs.name < rhs.name
        }
        index = [:]
        for (position, item) in results.enumerated() {
            index[item.id] = position
        }
    }
}
