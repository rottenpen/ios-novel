import SwiftUI
import ReaderCore

/// 搜索页：多书源并发聚合搜索，边搜边出结果。
struct SearchView: View {
    @EnvironmentObject private var sourceRepo: BookSourceRepository
    @EnvironmentObject private var shelf: BookshelfRepository
    @StateObject private var model = SearchModel()

    /// 来自发现页的待搜索关键词；切到本 Tab 后消费并清空。
    /// 默认 .constant(nil) 使其他调用方（如深链）无需关心此入参。
    var pendingKeyword: Binding<String?> = .constant(nil)

    @State private var input = ""
    @State private var selectedBook: Book?
    @State private var toast: String?
    @AppStorage("search.history") private var historyRaw = ""

    private var history: [String] {
        historyRaw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sourceRepo.enabledSources.isEmpty {
                    EmptyStateView(
                        icon: "antenna.radiowaves.left.and.right.slash",
                        title: "没有可用书源",
                        message: "搜索依赖书源，请先到「书源」页导入并启用"
                    )
                } else if model.results.isEmpty && !model.isSearching {
                    idleContent
                } else {
                    resultList
                }
            }
            .background(AppBackground())
            .navigationTitle("搜索")
            .searchable(text: $input, prompt: "书名 / 作者")
            .onSubmit(of: .search) { startSearch(input) }
            .safeAreaInset(edge: .top) {
                if model.isSearching || model.searchedCount > 0 {
                    progressBar
                }
            }
            .navigationDestination(item: $selectedBook) { book in
                BookDetailView(book: book)
            }
            .toast($toast)
            // 支持 yuedu://search?q=关键词 深链直达搜索，
            // 便于从外部跳转，也让「输入中文关键词」这条路径可被自动化验证。
            .onOpenURL { url in
                guard url.scheme == "yuedu", url.host == "search",
                      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems,
                      let q = items.first(where: { $0.name == "q" })?.value,
                      !q.isEmpty else { return }
                input = q
                startSearch(q)
            }
            .onChange(of: pendingKeyword.wrappedValue) { _, keyword in
                guard let keyword, !keyword.isEmpty else { return }
                input = keyword
                startSearch(keyword)
                // 消费后清空，避免返回本 Tab 时重复触发
                pendingKeyword.wrappedValue = nil
            }
            .task {
                // 首次进入时若已有待搜索词（例如发现页先于本 Tab 初始化），立即消费
                if let keyword = pendingKeyword.wrappedValue, !keyword.isEmpty {
                    input = keyword
                    startSearch(keyword)
                    pendingKeyword.wrappedValue = nil
                }
            }
        }
    }

    // MARK: - 进度条

    private var progressBar: some View {
        VStack(spacing: DS.Spacing.xs) {
            HStack {
                Text(model.isSearching ? "搜索中…" : "搜索完成")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(model.searchedCount)/\(model.totalCount) 源 · \(model.results.count) 本")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if model.isSearching {
                    Button("停止") { model.cancel() }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.accent)
                }
            }
            ProgressView(value: model.progress).tint(DS.accent)
        }
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.sm)
        .background(.bar)
    }

    // MARK: - 初始态

    private var idleContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                if !history.isEmpty {
                    HStack {
                        Text("搜索历史").font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("清空") { historyRaw = "" }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    FlowLayout(spacing: DS.Spacing.sm) {
                        ForEach(history, id: \.self) { item in
                            Button {
                                input = item
                                startSearch(item)
                            } label: {
                                Text(item).chipStyle()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text("当前可用书源 \(sourceRepo.enabledSources.count) 个")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("搜索会并发访问所有启用书源，结果按命中源数量排序")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, DS.Spacing.sm)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.lg)
        }
    }

    // MARK: - 结果列表

    private var resultList: some View {
        List(model.results) { item in
            Button {
                openBook(item)
            } label: {
                resultRow(item)
            }
            .buttonStyle(.plain)
            .listRowBackground(DS.card)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func resultRow(_ item: AggregatedBook) -> some View {
        HStack(spacing: DS.Spacing.md) {
            BookCover(url: item.coverUrl, fallbackText: item.name)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.xs) {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if item.sourceCount > 1 {
                        Text("\(item.sourceCount) 源").chipStyle()
                    }
                    if shelf.contains(item.primary?.bookUrl ?? "") {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(DS.accent)
                    }
                }
                if !item.author.isEmpty {
                    Text(item.author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let latest = item.latestChapterTitle, !latest.isEmpty {
                    Text("最新：\(latest)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let intro = item.intro, !intro.isEmpty {
                    Text(intro)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    // MARK: - 动作

    private func startSearch(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saveHistory(trimmed)
        model.search(keyword: trimmed, sources: sourceRepo.enabledSources)
    }

    private func saveHistory(_ keyword: String) {
        var list = history.filter { $0 != keyword }
        list.insert(keyword, at: 0)
        historyRaw = list.prefix(12).joined(separator: "\n")
    }

    private func openBook(_ item: AggregatedBook) {
        guard let search = item.primary else { return }
        var book = Book.from(searchBook: search)
        // 聚合信息回填，详情页未加载前也能展示
        if book.coverUrl == nil { book.coverUrl = item.coverUrl }
        if book.intro == nil { book.intro = item.intro }
        selectedBook = book
    }
}

/// 简易流式布局，用于标签换行排列
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
