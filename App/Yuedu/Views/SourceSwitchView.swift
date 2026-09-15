import SwiftUI
import ReaderCore

struct SourceSwitchView: View {
    let book: Book
    let chapterTitle: String
    let chapterIndex: Int
    let onSelect: (Book, [BookChapter], Int, String) -> Void

    @EnvironmentObject private var sources: BookSourceRepository
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = SearchModel()
    @State private var preparation: Task<Void, Never>?
    @State private var loadingID: String?
    @State private var error: String?
    @State private var preview: SourcePreview?

    private struct SourcePreview {
        let book: Book
        let chapters: [BookChapter]
        let match: ChapterMatcher.Match
        let content: String
    }

    private var candidates: [SearchBook] {
        search.results.filter { ChapterMatcher.sameBookName($0.name, book.name) }
            .flatMap(\.origins)
            .filter { $0.origin != book.origin }
            .sorted {
                let left = $0.author == book.author
                let right = $1.author == book.author
                if left != right { return left }
                return $0.originName.localizedStandardCompare($1.originName) == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("当前书源", value: book.originName)
                    Text(chapterTitle).font(.subheadline).foregroundStyle(.secondary)
                } header: { Text(book.name) }

                if let preview {
                    Section("确认章节") {
                        Text(preview.book.originName).font(.headline)
                        Text(preview.chapters[preview.match.index].title)
                        Text("目录 \(preview.chapters.count) 章 · 本章已加载 \(preview.content.count) 字")
                            .font(.caption).foregroundStyle(.secondary)
                        if !preview.match.matchedTitle {
                            Text("未找到相同标题，已按原目录位置定位。请核对章节，切换后也可从目录重新选择。")
                                .font(.footnote).foregroundStyle(.orange)
                        }
                        Text(String(preview.content.prefix(160)))
                            .font(.footnote).lineLimit(4).foregroundStyle(.secondary)
                        Button("切换并阅读") {
                            search.cancel()
                            dismiss()
                            onSelect(preview.book, preview.chapters, preview.match.index, preview.content)
                        }
                        .accessibilityIdentifier("sourceSwitch.confirm")
                    }
                }

                if let error {
                    Section { Text(error).font(.footnote).foregroundStyle(.red) }
                }

                Section {
                    if search.isSearching {
                        HStack {
                            ProgressView()
                            Text("正在查找其他书源… \(search.searchedCount)/\(search.totalCount)")
                                .font(.caption)
                        }
                    }
                    if candidates.isEmpty && !search.isSearching {
                        Text("没有找到同名书。可到「书源」页导入或启用其他书源后重试。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { candidate in
                        Button { prepare(candidate) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(candidate.originName).foregroundStyle(.primary)
                                    Text(candidate.author.isEmpty ? "作者未提供" : candidate.author)
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let latest = candidate.latestChapterTitle, !latest.isEmpty {
                                        Text(latest).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                if loadingID == candidate.id { ProgressView() }
                                else { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
                            }
                        }
                        .disabled(loadingID != nil)
                    }
                } header: { Text("其他书源 · \(candidates.count)") }
                  footer: { Text("点击书源可先检查目录和正文。切换后从对应章节开头继续阅读。") }
            }
            .navigationTitle("换源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { preparation?.cancel(); search.cancel(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(search.isSearching ? "停止搜索" : "重新搜索") {
                        if search.isSearching { search.cancel() } else { startSearch() }
                    }.disabled(loadingID != nil)
                }
            }
            .task { startSearch() }
            .onDisappear { preparation?.cancel(); search.cancel() }
        }
    }

    private func startSearch() {
        error = nil
        search.search(keyword: book.name, sources: sources.enabledSources.filter { $0.bookSourceUrl != book.origin })
    }

    private func prepare(_ candidate: SearchBook) {
        guard let source = sources.source(for: candidate.origin) else { return }
        loadingID = candidate.id
        preview = nil
        error = nil
        preparation = Task {
            defer { loadingID = nil }
            do {
                var target = Book.from(searchBook: candidate)
                // 部分书源直接在搜索结果中提供目录地址，详情失败仍可尝试目录。
                do { target = try await WebBook.bookInfo(source: source, book: target) }
                catch { try Task.checkCancellation() }
                try Task.checkCancellation()
                let chapters = try await WebBook.chapterList(source: source, book: target)
                try Task.checkCancellation()
                guard let match = ChapterMatcher.match(title: chapterTitle, index: chapterIndex, chapters: chapters) else {
                    error = "这个书源没有可阅读的章节，请选择其他书源。"
                    return
                }
                let content = try await WebBook.content(source: source, book: target, chapter: chapters[match.index],
                                                       nextChapterUrl: chapters[safe: match.index + 1]?.url)
                try Task.checkCancellation()
                preview = SourcePreview(book: target, chapters: chapters, match: match, content: content)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "该书源加载失败：\(error.localizedDescription)"
            }
        }
    }
}

/// 换源时重建阅读会话，避免旧分页、预加载任务和文字偏移影响新正文。
struct ReaderHostView: View {
    let onSourceChange: (Book, [BookChapter]) -> Void
    @State private var selection: Selection

    private struct Selection {
        let id = UUID()
        let book: Book
        let chapters: [BookChapter]
        let index: Int
        let offset: Int
    }

    init(book: Book, chapters: [BookChapter], startIndex: Int, startPosition: Int,
         onSourceChange: @escaping (Book, [BookChapter]) -> Void) {
        self.onSourceChange = onSourceChange
        _selection = State(initialValue: Selection(book: book, chapters: chapters, index: startIndex, offset: startPosition))
    }

    var body: some View {
        ReaderView(book: selection.book, chapters: selection.chapters,
                   startIndex: selection.index, startPosition: selection.offset) { book, chapters, index in
            selection = Selection(book: book, chapters: chapters, index: index, offset: 0)
            onSourceChange(book, chapters)
        }
        .id(selection.id)
    }
}
