import Foundation
import Combine

/// 阅读位置采用正文 UTF-16 偏移，排版变化后仍可定位到同一段文字。
@MainActor
public final class ReadingSession: ObservableObject {
    @Published public private(set) var chapterIndex: Int
    @Published public private(set) var pageIndex = 0
    @Published public private(set) var pagination: TextPagination?
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?
    @Published public var message: String?
    public private(set) var anchor: Int

    private let chapterCount: Int
    private var layout: PageLayout?
    /// 各章图片锚点（offset→URL），由 App 层解析 `<img>` 后注入
    private var anchorsByChapter: [Int: [ImageAnchor]] = [:]
    private var loader: (@MainActor (Int) async throws -> String)?
    private var progress: (@MainActor (Int, Int) -> Void)?
    private var generation = UUID()
    private var contents: [Int: String] = [:]
    private var requests: [Int: (id: UUID, task: Task<String, Error>)] = [:]
    private var prefetchTask: Task<Void, Never>?
    var loadTask: Task<Void, Never>?
    var cachedChapterCount: Int { contents.count }

    public init(chapterCount: Int, startIndex: Int, startOffset: Int = 0) {
        self.chapterCount = chapterCount
        chapterIndex = max(0, min(startIndex, max(0, chapterCount - 1)))
        anchor = max(0, startOffset)
    }

    public func start(
        load: @escaping @MainActor (Int) async throws -> String,
        onProgress: @escaping @MainActor (Int, Int) -> Void
    ) {
        loader = load
        progress = onProgress
    }

    /// 注入某章正文的图片锚点（在 loader 返回该章正文前调用）。
    public func setImageAnchors(_ anchors: [ImageAnchor], forChapter index: Int) {
        anchorsByChapter[index] = anchors
    }

    /// 当前章图片锚点（滚动模式分段渲染用）。
    public func currentImageAnchors() -> [ImageAnchor] {
        anchorsByChapter[chapterIndex] ?? []
    }

    public func configure(_ value: PageLayout) {
        guard layout != value || pagination == nil else { return }
        layout = value
        show(chapter: chapterIndex, offset: anchor)
    }

    public func goToChapter(_ index: Int) {
        guard (0..<chapterCount).contains(index) else { return }
        show(chapter: index, offset: 0)
    }

    /// 跳到指定章节的章内文字偏移（用于书签回跳）。
    public func goToChapter(_ index: Int, offset: Int) {
        guard (0..<chapterCount).contains(index) else { return }
        show(chapter: index, offset: max(0, offset))
    }

    /// 滚动模式下的轻量进度上报：只更新锚点与书架进度，不触发重排。
    public func markProgress(offset: Int) {
        let length = (pagination?.text as NSString?)?.length ?? 0
        let clamped = min(max(0, offset), max(0, length - 1))
        anchor = clamped
        progress?(chapterIndex, anchor)
    }

    public func retry() { show(chapter: chapterIndex, offset: anchor) }

    public func turn(_ direction: Int) {
        guard !isLoading, let pagination, direction != 0 else { return }
        let next = pageIndex + (direction > 0 ? 1 : -1)
        if pagination.ranges.indices.contains(next) {
            pageIndex = next
            anchor = pagination.ranges[next].location
            progress?(chapterIndex, anchor)
        } else {
            let chapter = chapterIndex + (direction > 0 ? 1 : -1)
            guard (0..<chapterCount).contains(chapter) else {
                message = direction > 0 ? "已到全书末尾" : "已到全书开头"
                return
            }
            show(chapter: chapter, offset: direction > 0 ? 0 : Int.max)
        }
    }

    public func stop() {
        generation = UUID()
        loadTask?.cancel()
        prefetchTask?.cancel()
        requests.values.forEach { $0.task.cancel() }
        requests.removeAll()
    }

    private func show(chapter: Int, offset: Int) {
        guard chapterCount > 0, let layout, loader != nil else { return }
        generation = UUID()
        let token = generation
        loadTask?.cancel()
        prefetchTask?.cancel()
        chapterIndex = chapter
        anchor = offset
        pagination = nil
        pageIndex = 0
        errorMessage = nil
        isLoading = true
        trimCache()
        loadTask = Task {
            do {
                let text = try await content(at: chapter)
                try Task.checkCancellation()
                let images = anchorsByChapter[chapter] ?? []
                let calculation = Task.detached(priority: .userInitiated) {
                    try TextPagination(text: text, layout: layout, images: images)
                }
                let pages = try await withTaskCancellationHandler {
                    try await calculation.value
                } onCancel: { calculation.cancel() }
                guard generation == token, !Task.isCancelled else { return }
                pagination = pages
                pageIndex = pages.page(containing: offset)
                anchor = offset == Int.max ? pages.ranges[pageIndex].location : min(offset, max(0, (text as NSString).length - 1))
                isLoading = false
                progress?(chapter, anchor)
                prefetchTask = Task {
                    for index in [chapter + 1, chapter - 1] where (0..<chapterCount).contains(index) {
                        guard !Task.isCancelled else { return }
                        _ = try? await content(at: index)
                    }
                }
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                isLoading = false
                errorMessage = error.localizedDescription
                JSLog.shared.append("正文加载或分页失败（第\(chapter + 1)章）")
            }
        }
    }

    private func content(at index: Int) async throws -> String {
        if let text = contents[index] { return text }
        guard let loader else { throw CancellationError() }
        let request: (id: UUID, task: Task<String, Error>)
        if let existing = requests[index] {
            request = existing
        } else {
            request = (UUID(), Task { try await loader(index) })
            requests[index] = request
        }
        do {
            let text = try await request.task.value
            if requests[index]?.id == request.id {
                requests[index] = nil
                if abs(index - chapterIndex) <= 1 { contents[index] = text }
            }
            return text
        } catch {
            if requests[index]?.id == request.id { requests[index] = nil }
            throw error
        }
    }

    private func trimCache() {
        contents = contents.filter { abs($0.key - chapterIndex) <= 1 }
        for index in Array(requests.keys) where abs(index - chapterIndex) > 1 {
            requests.removeValue(forKey: index)?.task.cancel()
        }
    }
}
