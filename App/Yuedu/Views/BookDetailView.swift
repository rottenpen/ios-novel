import SwiftUI
import ReaderCore

/// 书籍详情页：加载详情 + 目录，提供加入书架与开始阅读。
struct BookDetailView: View {
    let book: Book

    @EnvironmentObject private var shelf: BookshelfRepository
    @EnvironmentObject private var sourceRepo: BookSourceRepository
    @EnvironmentObject private var downloader: DownloadManager
    @Environment(\.dismiss) private var dismiss

    @State private var detail: Book
    @State private var chapters: [BookChapter] = []
    @State private var isLoadingInfo = false
    @State private var isLoadingToc = false
    @State private var errorMessage: String?
    @State private var toast: String?
    @State private var showAllChapters = false
    @State private var readingChapter: ReadingTarget?
    @State private var introExpanded = false
    /// 已缓存章节下标快照。一次目录扫描得出，供菜单与目录区复用，
    /// 避免千章级书籍每次界面重绘都逐章查盘；下载推进时刷新。
    @State private var cachedSnapshot: Set<Int> = []

    init(book: Book) {
        self.book = book
        _detail = State(initialValue: book)
    }

    private var source: BookSource? {
        sourceRepo.source(for: detail.origin)
    }

    private var inShelf: Bool { shelf.contains(detail.bookUrl) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                header
                actionButtons
                if isDownloadingThis {
                    downloadProgressCard
                }
                if let intro = detail.displayIntro, !intro.isEmpty {
                    introSection(intro)
                }
                chapterSection
            }
            .padding(DS.Spacing.lg)
        }
        .background(AppBackground())
        .navigationTitle(detail.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await loadAll(force: true) }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    Divider()
                    if isDownloadingThis {
                        Button(role: .destructive) {
                            downloader.cancel()
                        } label: {
                            Label("停止下载", systemImage: "stop.circle")
                        }
                    } else {
                        Button {
                            startDownload()
                        } label: {
                            Label(downloadTitle, systemImage: "arrow.down.circle")
                        }
                        .disabled(chapters.isEmpty || source == nil || downloader.isDownloading)
                        if uncachedCount > 0, uncachedCount < chapters.count {
                            Button {
                                startDownload(fromCurrent: true)
                            } label: {
                                Label("从当前章往后下载", systemImage: "arrow.down.to.line")
                            }
                            .disabled(source == nil || downloader.isDownloading)
                        }
                    }
                    if !downloader.failedChapters.isEmpty, !downloader.isDownloading {
                        Button {
                            retryFailed()
                        } label: {
                            Label("重试失败的 \(downloader.failedChapters.count) 章", systemImage: "arrow.clockwise.circle")
                        }
                        .disabled(source == nil)
                    }
                    if cachedCount > 0 {
                        Button(role: .destructive) {
                            shelf.clearCache(for: detail.bookUrl)
                            shelf.flush()
                            refreshCachedSnapshot()
                            toast = "已清除本书缓存"
                        } label: {
                            Label("清除本书缓存", systemImage: "trash.slash")
                        }
                        .disabled(isDownloadingThis)
                    }
                    if inShelf {
                        Divider()
                        Button(role: .destructive) {
                            shelf.remove(detail.bookUrl)
                            toast = "已移出书架"
                        } label: {
                            Label("移出书架", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            await loadAll(force: false)
            // 目录就绪后再扫一次，首次进入即可显示正确的已缓存数
            refreshCachedSnapshot()
        }
        // 下载结束后的结果提示统一走详情页的 toast
        .onChange(of: downloader.message) { _, text in
            guard let text else { return }
            toast = text
            refreshCachedSnapshot()
            downloader.message = nil
        }
        // 每完成一章就刷新目录里的已下载标记
        .onChange(of: downloader.progress.completed) { _, _ in
            refreshCachedSnapshot()
        }
        .fullScreenCover(item: $readingChapter) { target in
            ReaderHostView(
                book: detail,
                chapters: chapters,
                startIndex: target.index,
                startPosition: target.position
            ) { updated, catalog in
                detail = updated
                chapters = catalog
            }
        }
        .toast($toast)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Spacing.lg) {
            BookCover(
                url: detail.displayCover,
                width: DS.Cover.detailWidth,
                height: DS.Cover.detailHeight,
                fallbackText: detail.name
            )
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Text(detail.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(3)
                if !detail.author.isEmpty {
                    Label(detail.author, systemImage: "person")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let kind = detail.kind, !kind.isEmpty {
                    Text(kind)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                HStack(spacing: DS.Spacing.sm) {
                    if let words = detail.wordCount, !words.isEmpty {
                        Text(words).chipStyle()
                    }
                    if !detail.originName.isEmpty {
                        Text(detail.originName).chipStyle(color: .secondary)
                    }
                }
                if let latest = detail.latestChapterTitle, !latest.isEmpty {
                    Text("最新：\(latest)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if isLoadingInfo {
                    ProgressView().controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 操作按钮

    private var actionButtons: some View {
        VStack(spacing: DS.Spacing.md) {
            HStack(spacing: DS.Spacing.md) {
                Button {
                    startReading()
                } label: {
                    Label(continueTitle, systemImage: "book")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(DS.accent)
                .disabled(chapters.isEmpty)

                Button {
                    toggleShelf()
                } label: {
                    Label(
                        inShelf ? "已在书架" : "加入书架",
                        systemImage: inShelf ? "checkmark" : "plus"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(inShelf ? .secondary : DS.accent)
            }

            // 整本下载：核心功能提到主操作区，一眼可见、状态自适应
            Button {
                if isDownloadingThis {
                    downloader.cancel()
                } else {
                    startDownload()
                }
            } label: {
                Label {
                    if isDownloadingThis {
                        let p = downloader.progress
                        Text("下载中 \(p.handled)/\(p.total) · 点击停止")
                    } else {
                        Text(downloadTitle)
                    }
                } icon: {
                    Image(systemName: isDownloadingThis ? "stop.circle" : "arrow.down.circle")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(isDownloadingThis ? .secondary : DS.accent)
            .disabled(chapters.isEmpty || source == nil
                      || (!isDownloadingThis && uncachedCount == 0)
                      || (!isDownloadingThis && downloader.isDownloading))
        }
    }

    private var continueTitle: String {
        guard inShelf,
              let saved = shelf.shelfBook(for: detail.bookUrl),
              saved.lastReadAt != nil else {
            return "开始阅读"
        }
        return "继续阅读"
    }

    // MARK: - 下载

    private var isDownloadingThis: Bool {
        downloader.isDownloading(bookUrl: detail.bookUrl)
    }

    private var cachedIndexes: Set<Int> { cachedSnapshot }

    /// 只统计当前目录范围内的缓存，避免换源后残留文件让计数虚高
    private var cachedCount: Int {
        let cached = cachedSnapshot
        return chapters.indices.reduce(into: 0) { total, index in
            if cached.contains(index) { total += 1 }
        }
    }

    private var uncachedCount: Int { max(0, chapters.count - cachedCount) }

    private var downloadTitle: String {
        if chapters.isEmpty { return "下载全本" }
        if uncachedCount == 0 { return "已全部缓存" }
        if cachedCount > 0 { return "继续下载剩余 \(uncachedCount) 章" }
        return "下载全本 \(chapters.count) 章"
    }

    private var downloadProgressCard: some View {
        let progress = downloader.progress
        return VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack {
                Label("正在下载", systemImage: "arrow.down.circle")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(progress.handled) / \(progress.total)")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress.fraction).tint(DS.accent)
            HStack(spacing: DS.Spacing.md) {
                if progress.failed > 0 {
                    Text("失败 \(progress.failed)")
                        .font(.caption2).foregroundStyle(.orange)
                }
                if progress.skipped > 0 {
                    Text("已跳过 \(progress.skipped)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("停止") { downloader.cancel() }
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func refreshCachedSnapshot() {
        cachedSnapshot = shelf.cachedChapterIndexes(bookUrl: detail.bookUrl)
    }

    private func startDownload(fromCurrent: Bool = false) {
        guard let source else {
            toast = "找不到对应书源，无法下载"
            return
        }
        guard !chapters.isEmpty else { return }
        // 下载会写入书架缓存目录，先确保这本书在架，避免产生孤立缓存
        if !inShelf { toggleShelf() }
        let range: [Int]? = fromCurrent
            ? Array(currentChapterIndex..<chapters.count)
            : nil
        downloader.start(
            book: detail, chapters: chapters, source: source,
            shelf: shelf, range: range
        )
    }

    private func retryFailed() {
        guard let source else { return }
        downloader.retryFailed(
            book: detail, chapters: chapters, source: source, shelf: shelf
        )
    }

    private var currentChapterIndex: Int {
        let saved = shelf.shelfBook(for: detail.bookUrl)?.book.durChapterIndex ?? 0
        return max(0, min(saved, max(0, chapters.count - 1)))
    }

    // MARK: - 简介

    private func introSection(_ intro: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text("简介").font(.subheadline.weight(.semibold))
            Text(intro)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(introExpanded ? nil : 4)
                .animation(DS.Motion.gentle, value: introExpanded)
            Button(introExpanded ? "收起" : "展开") {
                withAnimation(DS.Motion.gentle) { introExpanded.toggle() }
            }
            .font(.caption)
            .foregroundStyle(DS.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - 目录

    private var chapterSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                Text("目录").font(.subheadline.weight(.semibold))
                if !chapters.isEmpty {
                    Text("\(chapters.count) 章")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if cachedCount > 0 {
                        Text("已缓存 \(cachedCount)").chipStyle()
                    }
                }
                Spacer()
                if isLoadingToc {
                    ProgressView().controlSize(.small)
                }
            }

            if let errorMessage {
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("重试") { Task { await loadAll(force: true) } }
                        .font(.caption)
                        .buttonStyle(.bordered)
                }
            }

            if chapters.isEmpty && !isLoadingToc && errorMessage == nil {
                Text("暂无目录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let preview = showAllChapters ? chapters : Array(chapters.prefix(20))
            // 复用同一份缓存快照，整段目录只读一次
            let cached = cachedSnapshot
            VStack(spacing: 0) {
                ForEach(preview) { chapter in
                    Button {
                        startReading(at: chapters.firstIndex { $0.id == chapter.id } ?? chapter.index)
                    } label: {
                        HStack(spacing: DS.Spacing.sm) {
                            Text(chapter.title)
                                .font(.subheadline)
                                .foregroundStyle(chapter.isVolume ? DS.accent : .primary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if chapter.isVip {
                                Image(systemName: "lock")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            if cached.contains(chapter.index) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(DS.accent.opacity(0.6))
                            }
                        }
                        .padding(.vertical, DS.Spacing.md)
                    }
                    .buttonStyle(.plain)
                    if chapter.id != preview.last?.id {
                        Divider().overlay(DS.separator)
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.md)
            .background(DS.card)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))

            if chapters.count > 20 {
                Button(showAllChapters ? "收起目录" : "展开全部 \(chapters.count) 章") {
                    withAnimation(DS.Motion.gentle) { showAllChapters.toggle() }
                }
                .font(.subheadline)
                .foregroundStyle(DS.accent)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - 数据加载

    private func loadAll(force: Bool) async {
        // 已缓存目录可在书源缺失或离线时继续使用。
        if !force || source == nil {
            let cached = shelf.loadChapters(for: detail.bookUrl)
            if !cached.isEmpty {
                chapters = cached
                errorMessage = nil
                if let saved = shelf.shelfBook(for: detail.bookUrl) {
                    detail = saved.book
                }
                return
            }
        }

        guard let source else {
            errorMessage = "找不到对应书源，且没有本地目录缓存"
            return
        }
        errorMessage = nil
        isLoadingInfo = true
        do {
            detail = try await WebBook.bookInfo(source: source, book: detail)
        } catch {
            // 详情失败不阻断目录：部分书源详情页与目录页同源
            errorMessage = "详情加载失败：\(error.localizedDescription)"
        }
        isLoadingInfo = false

        isLoadingToc = true
        do {
            let list = try await WebBook.chapterList(source: source, book: detail)
            chapters = list
            errorMessage = nil
            shelf.saveChapters(list, for: detail.bookUrl)
            detail.totalChapterNum = list.count
            if inShelf {
                shelf.update(detail)
                shelf.updateChapterCount(bookUrl: detail.bookUrl, count: list.count)
            }
        } catch {
            errorMessage = "目录加载失败：\(error.localizedDescription)"
        }
        isLoadingToc = false
    }

    private func toggleShelf() {
        if inShelf {
            shelf.remove(detail.bookUrl)
            toast = "已移出书架"
        } else {
            var target = detail
            target.totalChapterNum = chapters.count
            shelf.add(target)
            if !chapters.isEmpty {
                shelf.saveChapters(chapters, for: target.bookUrl)
            }
            toast = "已加入书架"
        }
    }

    private func startReading(at index: Int? = nil) {
        guard let position = shelf.beginReading(book: detail, chapters: chapters, chapterIndex: index) else { return }
        readingChapter = ReadingTarget(index: position.chapter, position: position.offset)
    }

}

/// 阅读目标，用于 fullScreenCover(item:)
struct ReadingTarget: Identifiable {
    let index: Int
    let position: Int
    var id: Int { index }
}
