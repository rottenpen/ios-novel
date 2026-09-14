import SwiftUI
import ReaderCore

/// 书籍详情页：加载详情 + 目录，提供加入书架与开始阅读。
struct BookDetailView: View {
    let book: Book

    @EnvironmentObject private var shelf: BookshelfRepository
    @EnvironmentObject private var sourceRepo: BookSourceRepository
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
                if let intro = detail.displayIntro, !intro.isEmpty {
                    introSection(intro)
                }
                chapterSection
            }
            .padding(DS.Spacing.lg)
        }
        .background(DS.canvas)
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
                    if inShelf {
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
        .task { await loadAll(force: false) }
        .fullScreenCover(item: $readingChapter) { target in
            ReaderView(
                book: detail,
                chapters: chapters,
                startIndex: target.index,
                startPosition: target.position
            )
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
    }

    private var continueTitle: String {
        guard inShelf,
              let saved = shelf.shelfBook(for: detail.bookUrl),
              saved.lastReadAt != nil else {
            return "开始阅读"
        }
        return "继续阅读"
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
                            if shelf.hasContent(
                                bookUrl: detail.bookUrl, chapterIndex: chapter.index
                            ) {
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
