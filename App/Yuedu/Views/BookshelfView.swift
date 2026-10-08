import SwiftUI
import ReaderCore

/// 书架页：网格 / 列表双视图，支持进度、更新角标、长按管理。
struct BookshelfView: View {
    @EnvironmentObject private var shelf: BookshelfRepository
    @EnvironmentObject private var sourceRepo: BookSourceRepository
    @EnvironmentObject private var downloader: DownloadManager

    @AppStorage("shelf.isGrid") private var isGrid = true
    @State private var searchText = ""
    @State private var selectedBook: Book?
    @State private var toast: String?
    @State private var isRefreshing = false
    @State private var showSettings = false
    /// 每本书已缓存章节数快照（异步扫描，供「已缓存全本」徽标）
    @State private var cachedCounts: [String: Int] = [:]
    /// 阅读统计（@Observable，数据变化自动刷新）
    @State private var stats = ReadingStatsStore.shared

    private var filtered: [ShelfBook] {
        guard !searchText.isEmpty else { return shelf.books }
        let key = searchText.lowercased()
        return shelf.books.filter {
            $0.book.name.lowercased().contains(key)
                || $0.book.author.lowercased().contains(key)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !shelf.books.isEmpty && searchText.isEmpty {
                    statsCard
                }
                Group {
                if shelf.books.isEmpty {
                    EmptyStateView(
                        icon: "books.vertical",
                        title: "书架还是空的",
                        message: sourceRepo.sources.isEmpty
                            ? "先到「书源」页导入书源，再搜索添加书籍"
                            : "到「搜索」页找一本书加入书架吧"
                    )
                } else if filtered.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: "没有匹配的书")
                } else if isGrid {
                    gridContent
                } else {
                    listContent
                }
                }
            }
            .background(AppBackground())
            .task { await refreshCachedCounts() }
            .navigationTitle("书架")
            .searchable(text: $searchText, prompt: "筛选书架")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("显示方式", selection: $isGrid) {
                            Label("网格", systemImage: "square.grid.2x2").tag(true)
                            Label("列表", systemImage: "list.bullet").tag(false)
                        }
                        Divider()
                        Button {
                            Task { await refreshAll() }
                        } label: {
                            Label("检查全部更新", systemImage: "arrow.clockwise")
                        }
                        .disabled(isRefreshing || shelf.books.isEmpty)
                        Divider()
                        Button {
                            showSettings = true
                        } label: {
                            Label("设置", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .navigationDestination(item: $selectedBook) { book in
                BookDetailView(book: book)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .overlay(alignment: .top) {
                if isRefreshing {
                    ProgressView("正在检查更新…")
                        .padding(DS.Spacing.md)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, DS.Spacing.sm)
                } else if downloader.isDownloading {
                    downloadBanner
                }
            }
            // 下载可能在其他页面发起，结果提示统一在书架也能看到
            .onChange(of: downloader.message) { _, text in
                guard let text else { return }
                toast = text
                downloader.message = nil
                Task { await refreshCachedCounts() }
            }
            .onChange(of: downloader.progress.completed) { _, _ in
                Task { await refreshCachedCounts() }
            }
            .toast($toast)
        }
    }

    /// 顶部下载条：任何页面发起的下载都能在书架看到进度并停止
    private var downloadBanner: some View {
        let progress = downloader.progress
        let name = downloader.activeBookUrl
            .flatMap { shelf.shelfBook(for: $0)?.book.name } ?? "正在下载"
        return HStack(spacing: DS.Spacing.sm) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text("\(progress.handled) / \(progress.total) 章")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button("停止") { downloader.cancel() }
                .font(.caption)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, DS.Spacing.md)
        .padding(.vertical, DS.Spacing.sm)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, DS.Spacing.sm)
    }

    // MARK: - 网格

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: DS.Cover.gridWidth), spacing: DS.Spacing.lg)],
                spacing: DS.Spacing.xl
            ) {
                ForEach(filtered) { item in
                    Button {
                        selectedBook = item.book
                    } label: {
                        gridCell(item)
                    }
                    .buttonStyle(PressableScaleButtonStyle())
                    .contextMenu { contextMenu(for: item) }
                }
            }
            .padding(DS.Spacing.lg)
        }
        .refreshable { await refreshAll() }
    }

    private func gridCell(_ item: ShelfBook) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            ZStack(alignment: .topTrailing) {
                BookCover(
                    url: item.book.displayCover,
                    width: DS.Cover.gridWidth,
                    height: DS.Cover.gridHeight,
                    fallbackText: item.book.name
                )
                HStack(spacing: 4) {
                    if isFullyCached(item) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                            .padding(2)
                            .background(Circle().fill(.black.opacity(0.45)))
                    }
                    if item.hasUpdate {
                        Circle()
                            .fill(DS.highlight)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                    }
                }
                .offset(x: 4, y: -4)
            }
            .overlay(alignment: .bottom) {
                if item.progress > 0 {
                    GeometryReader { geo in
                        Capsule()
                            .fill(DS.accent)
                            .frame(width: geo.size.width * item.progress, height: 3)
                            .animation(DS.Motion.standard, value: item.progress)
                    }
                    .frame(height: 3)
                    .background(Color.black.opacity(0.15))
                }
            }

            Text(item.book.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: DS.Cover.gridWidth, alignment: .leading)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - 列表

    private var listContent: some View {
        List {
            ForEach(filtered) { item in
                Button {
                    selectedBook = item.book
                } label: {
                    listRow(item)
                }
                .buttonStyle(PressableScaleButtonStyle())
                .listRowBackground(DS.card)
                .contextMenu { contextMenu(for: item) }
            }
            .onDelete { offsets in
                let targets = offsets.map { filtered[$0].book.bookUrl }
                withAnimation(DS.Motion.standard) {
                    for url in targets { shelf.remove(url) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await refreshAll() }
    }

    // MARK: - 阅读统计卡片

    private var statsCard: some View {
        HStack(spacing: 0) {
            statsCell(title: "今日", value: ReadingStatsStore.formatDuration(stats.todaySeconds), detail: "\(stats.todayChapters) 章")
            statsDivider
            statsCell(title: "连续阅读", value: "\(stats.streakDays) 天", detail: stats.streakDays > 0 ? "保持节奏" : "今天开始")
            statsDivider
            statsCell(title: "累计", value: ReadingStatsStore.formatDuration(stats.totalSeconds), detail: "\(stats.totalChapters) 章")
        }
        .padding(.vertical, DS.Spacing.md)
        .padding(.horizontal, DS.Spacing.lg)
        .glassCardStyle()
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.top, DS.Spacing.sm)
    }

    private var statsDivider: some View {
        Rectangle()
            .fill(DS.separator)
            .frame(width: 1, height: 36)
            .padding(.horizontal, DS.Spacing.lg)
    }

    private func statsCell(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func listRow(_ item: ShelfBook) -> some View {
        HStack(spacing: DS.Spacing.md) {
            BookCover(
                url: item.book.displayCover,
                fallbackText: item.book.name
            )
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.xs) {
                    Text(item.book.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if isFullyCached(item) {
                        Text("已缓存").chipStyle(color: .green)
                    }
                    if item.hasUpdate {
                        Text("更新").chipStyle(color: DS.highlight)
                    }
                }
                if !item.book.author.isEmpty {
                    Text(item.book.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let title = item.book.durChapterTitle {
                    Text("读到：\(title)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                } else if let latest = item.book.latestChapterTitle {
                    Text("最新：\(latest)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if item.book.totalChapterNum > 0 {
                    HStack(spacing: DS.Spacing.xs) {
                        ProgressView(value: item.progress)
                            .tint(DS.accent)
                            .frame(maxWidth: 120)
                            .animation(DS.Motion.standard, value: item.progress)
                        Text("\(Int(item.progress * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    // MARK: - 缓存状态

    /// 是否整本已缓存（有目录信息且缓存数 >= 总章数）
    private func isFullyCached(_ item: ShelfBook) -> Bool {
        item.book.totalChapterNum > 0
            && (cachedCounts[item.book.bookUrl] ?? 0) >= item.book.totalChapterNum
    }

    /// 异步扫描每本书的缓存章节数；进入书架、下载推进/结束、刷新目录时调用
    private func refreshCachedCounts() async {
        var counts: [String: Int] = [:]
        for item in shelf.books {
            counts[item.book.bookUrl] = shelf.cachedChapterIndexes(bookUrl: item.book.bookUrl).count
        }
        cachedCounts = counts
    }

    // MARK: - 菜单与操作

    @ViewBuilder
    private func contextMenu(for item: ShelfBook) -> some View {
        Button {
            selectedBook = item.book
        } label: {
            Label("查看详情", systemImage: "info.circle")
        }
        Button {
            UIPasteboard.general.string = item.book.name
        } label: {
            Label("复制书名", systemImage: "doc.on.doc")
        }
        if downloader.isDownloading(bookUrl: item.book.bookUrl) {
            Button(role: .destructive) {
                downloader.cancel()
            } label: {
                Label("停止下载", systemImage: "stop.circle")
            }
        } else if isFullyCached(item) {
            Button {
                toast = "本书已整本缓存"
            } label: {
                Label("已缓存全本", systemImage: "checkmark.circle")
            }
        } else {
            Button {
                startDownload(item)
            } label: {
                Label("下载全本", systemImage: "arrow.down.circle")
            }
            .disabled(downloader.isDownloading || sourceRepo.source(for: item.book.origin) == nil)
        }
        if item.hasUpdate {
            Button {
                shelf.markUpdateSeen(bookUrl: item.book.bookUrl)
            } label: {
                Label("标记已读", systemImage: "checkmark.circle")
            }
        }
        Button(role: .destructive) {
            withAnimation(DS.Motion.standard) { shelf.remove(item.book.bookUrl) }
            toast = "已从书架移除"
        } label: {
            Label("移出书架", systemImage: "trash")
        }
    }

    /// 从书架直接下载：用本地目录缓存，避免再等一次目录请求
    private func startDownload(_ item: ShelfBook) {
        guard let source = sourceRepo.source(for: item.book.origin) else {
            toast = "找不到对应书源"
            return
        }
        let chapters = shelf.loadChapters(for: item.book.bookUrl)
        guard !chapters.isEmpty else {
            toast = "没有目录缓存，请先打开详情页加载目录"
            return
        }
        downloader.start(book: item.book, chapters: chapters, source: source, shelf: shelf)
    }

    /// 批量检查更新：并发拉目录，只比较章节数
    private func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        // 在 MainActor 上先把 (书, 书源) 配好，闭包内不再访问 @MainActor 仓库
        let jobs: [(book: Book, source: BookSource)] = shelf.books.compactMap { item in
            guard let source = sourceRepo.source(for: item.book.origin) else { return nil }
            return (item.book, source)
        }
        var updated = 0

        await withTaskGroup(of: (String, [BookChapter])?.self) { group in
            var iterator = jobs.makeIterator()
            var running = 0
            let maxConcurrent = 4

            func addNext() -> Bool {
                guard let job = iterator.next() else { return false }
                group.addTask {
                    guard let chapters = try? await WebBook.chapterList(
                        source: job.source, book: job.book
                    ) else { return nil }
                    return (job.book.bookUrl, chapters)
                }
                return true
            }

            while running < maxConcurrent, addNext() { running += 1 }
            while let result = await group.next() {
                if let (url, chapters) = result {
                    let count = chapters.count
                    let old = shelf.shelfBook(for: url)?.book.totalChapterNum ?? 0
                    shelf.saveChapters(chapters, for: url)
                    shelf.updateChapterCount(bookUrl: url, count: count)
                    if count > old { updated += 1 }
                }
                _ = addNext()
            }
        }
        toast = updated > 0 ? "\(updated) 本有更新" : "暂无更新"
    }
}
