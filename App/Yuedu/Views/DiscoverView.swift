import SwiftUI
import ReaderCore

// MARK: - 数据模型

/// 内置推荐书单，随 App 打包（`discover_booklist.json`）。
/// 数据来自第三方公开推荐，能否搜到与阅读取决于所用书源的当前状态。
struct BookList: Decodable {
    struct Entry: Decodable, Identifiable {
        let title: String
        let author: String
        let genre: String?
        let tags: [String]
        let wordCount: String
        let site: String
        let rating: String
        let comment: String
        let related: [String]?
        var id: String { "\(title)|\(author)" }
    }
    struct Featured: Decodable, Identifiable {
        let name: String
        let books: [Entry]
        var id: String { name }
    }

    let title: String
    let subtitle: String
    let source: String
    let sourceUrl: String
    let note: String
    /// 顶部精选栏（本期新粮、封神榜）
    let featured: [Featured]
    /// 题材筛选条，首项为「全部」
    let genres: [String]
    /// 全部书目，按题材筛选浏览
    let books: [Entry]

    /// 从 App Bundle 加载；解析失败返回 nil，由界面兜底。
    static func loadBuiltin() -> BookList? {
        guard let url = Bundle.main.url(forResource: "discover_booklist", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(BookList.self, from: data)
    }
}

// MARK: - 发现页

/// 发现页：精选栏 + 按题材浏览 TOP100，点书直达搜索。
///
/// 用内置数据而非实时抓取：推荐榜不是实时行情，且公众号有防爬；
/// 固化成随包数据更稳定，点书后走既有的多书源搜索链路去实际站点找书。
struct DiscoverView: View {
    @EnvironmentObject private var sourceRepo: BookSourceRepository
    @Environment(\.openURL) private var openURL

    @State private var list: BookList?
    @State private var selectedGenre = "全部"
    /// 点书后携带关键词跳转搜索 Tab
    let onSearch: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let list {
                    content(list)
                } else {
                    EmptyStateView(
                        icon: "sparkles",
                        title: "暂无推荐内容",
                        message: "内置书单加载失败"
                    )
                }
            }
            .background(DiscoverBackground())
            .navigationTitle("发现")
        }
        .task {
            if list == nil { list = BookList.loadBuiltin() }
        }
    }

    /// 当前题材筛选后的书目
    private func filteredBooks(_ list: BookList) -> [BookList.Entry] {
        guard selectedGenre != "全部" else { return list.books }
        return list.books.filter { $0.genre == selectedGenre }
    }

    @ViewBuilder
    private func content(_ list: BookList) -> some View {
        VStack(spacing: 0) {
            // 题材条固定在顶部，常驻可见，不随内容滚走
            genreBar(list)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: DS.Spacing.xl) {
                    // 精选栏：仅在「全部」时展示，避免与题材浏览重复
                    if selectedGenre == "全部" {
                        ForEach(list.featured) { section in
                            featuredSection(section)
                        }
                    }

                    ForEach(filteredBooks(list)) { book in
                        bookCard(book)
                    }
                    if filteredBooks(list).isEmpty {
                        Text("该题材暂无书目")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, DS.Spacing.lg)
                    }
                    footer(list)
                }
                .padding(DS.Spacing.lg)
            }
        }
    }

    // MARK: - 头部与题材条

    /// 顶部横向题材筛选条，滚动时吸顶
    private func genreBar(_ list: BookList) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                ForEach(list.genres, id: \.self) { genre in
                    let selected = genre == selectedGenre
                    Button {
                        withAnimation(DS.Motion.quick) { selectedGenre = genre }
                    } label: {
                        Text(genre)
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .padding(.horizontal, DS.Spacing.md)
                            .padding(.vertical, DS.Spacing.xs)
                            .background(selected ? AnyShapeStyle(DS.accent) : AnyShapeStyle(.ultraThinMaterial))
                            .foregroundStyle(selected ? .white : .primary)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().strokeBorder(DS.separator, lineWidth: selected ? 0 : 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Spacing.lg)
            .padding(.vertical, DS.Spacing.sm)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - 精选栏

    private func featuredSection(_ section: BookList.Featured) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text(section.name)
                .font(.headline)
                .foregroundStyle(DS.accent)
            ForEach(section.books) { book in
                bookCard(book)
            }
        }
    }

    // MARK: - 书卡

    private func bookCard(_ book: BookList.Entry) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(book.title)
                    .font(.subheadline.weight(.semibold))
                Text(book.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if !book.rating.isEmpty {
                    Text(book.rating)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DS.highlight)
                        .monospacedDigit()
                }
            }

            FlowLayout(spacing: DS.Spacing.xs) {
                if let genre = book.genre, !genre.isEmpty {
                    Text(genre).chipStyle()
                }
                ForEach(book.tags, id: \.self) { tag in
                    Text(tag).chipStyle(color: .secondary)
                }
                if !book.wordCount.isEmpty {
                    Text(book.wordCount).chipStyle(color: .secondary)
                }
            }

            Text(book.comment)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let related = book.related, !related.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    Text("同类可看")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    FlowLayout(spacing: DS.Spacing.xs) {
                        ForEach(related, id: \.self) { name in
                            Button {
                                onSearch(name)
                            } label: {
                                Text(name)
                                    .font(.caption2)
                                    .padding(.horizontal, DS.Spacing.sm)
                                    .padding(.vertical, DS.Spacing.xxs)
                                    .background(DS.separator)
                                    .clipShape(Capsule())
                                    .foregroundStyle(.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // 整卡可点搜索；底部放轻量引导标识，替代原来的大按钮
            HStack(spacing: DS.Spacing.xs) {
                Spacer()
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                Text(sourceRepo.enabledSources.isEmpty ? "先启用书源" : "点击搜索这本书")
                    .font(.caption2)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(sourceRepo.enabledSources.isEmpty ? Color.secondary : DS.accent)
            .padding(.top, DS.Spacing.xxs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCardStyle()
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous))
        .onTapGesture {
            guard !sourceRepo.enabledSources.isEmpty else { return }
            onSearch(book.title)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(book.title)，\(book.author)"))
        .accessibilityHint(Text("搜索这本书"))
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - 页脚

    private func footer(_ list: BookList) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(list.note)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if sourceRepo.enabledSources.isEmpty {
                Text("提示：当前没有启用的书源，请先到「书源」页导入并启用后再搜索。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Button {
                if let url = URL(string: list.sourceUrl) { openURL(url) }
            } label: {
                Label("查看原文", systemImage: "safari")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, DS.Spacing.sm)
    }
}
