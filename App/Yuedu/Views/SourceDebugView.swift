import SwiftUI
import ReaderCore

/// 书源调试页：对单个书源跑通「搜索 → 详情 → 目录 → 正文」全链路，定位规则问题。
///
/// 这是书源类阅读器的刚需功能：书源随时可能失效，用户需要能自己判断
/// 是哪一环出了问题（搜索规则、详情规则、目录规则还是正文规则）。
struct SourceDebugView: View {
    let source: BookSource

    @Environment(\.dismiss) private var dismiss
    @State private var keyword = "剑来"
    @State private var steps: [DebugStep] = []
    @State private var isRunning = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("测试关键词", text: $keyword)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            Task { await run() }
                        } label: {
                            if isRunning {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("开始")
                            }
                        }
                        .disabled(isRunning || keyword.isEmpty)
                        .buttonStyle(.borderedProminent)
                        .tint(DS.accent)
                    }
                } header: {
                    Text(source.bookSourceName)
                } footer: {
                    Text("依次验证搜索、详情、目录、正文四个环节")
                }

                if !steps.isEmpty {
                    Section("调试结果") {
                        ForEach(steps) { step in
                            stepRow(step)
                        }
                    }
                }
            }
            .navigationTitle("书源调试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func stepRow(_ step: DebugStep) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: step.icon)
                    .foregroundStyle(step.color)
                Text(step.title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let duration = step.duration {
                    Text(String(format: "%.1fs", duration))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if !step.detail.isEmpty {
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(step.isError ? .red : .secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, DS.Spacing.xxs)
    }

    // MARK: - 调试流程

    private func run() async {
        isRunning = true
        steps = []
        defer { isRunning = false }

        // 1) 搜索
        let searchStart = Date()
        var books: [SearchBook] = []
        do {
            books = try await WebBook.search(source: source, key: keyword)
            append(DebugStep(
                title: "搜索",
                detail: books.isEmpty
                    ? "请求成功但未解析出结果，检查 ruleSearch.bookList"
                    : "找到 \(books.count) 条：\(books.prefix(3).map(\.name).joined(separator: "、"))",
                isError: books.isEmpty,
                duration: Date().timeIntervalSince(searchStart)
            ))
        } catch {
            append(DebugStep(
                title: "搜索",
                detail: error.localizedDescription,
                isError: true,
                duration: Date().timeIntervalSince(searchStart)
            ))
            return
        }
        guard let first = books.first else { return }

        // 2) 详情
        let infoStart = Date()
        var book = Book.from(searchBook: first)
        do {
            book = try await WebBook.bookInfo(source: source, book: book)
            append(DebugStep(
                title: "详情",
                detail: "《\(book.name)》\(book.author)\n目录地址：\(book.tocUrl)",
                isError: book.name.isEmpty,
                duration: Date().timeIntervalSince(infoStart)
            ))
        } catch {
            append(DebugStep(
                title: "详情",
                detail: error.localizedDescription,
                isError: true,
                duration: Date().timeIntervalSince(infoStart)
            ))
            return
        }

        // 3) 目录
        let tocStart = Date()
        var chapters: [BookChapter] = []
        do {
            chapters = try await WebBook.chapterList(source: source, book: book)
            append(DebugStep(
                title: "目录",
                detail: "共 \(chapters.count) 章，首章：\(chapters.first?.title ?? "-")",
                isError: chapters.isEmpty,
                duration: Date().timeIntervalSince(tocStart)
            ))
        } catch {
            append(DebugStep(
                title: "目录",
                detail: error.localizedDescription,
                isError: true,
                duration: Date().timeIntervalSince(tocStart)
            ))
            return
        }
        guard let firstChapter = chapters.first else { return }

        // 4) 正文
        let contentStart = Date()
        do {
            let text = try await WebBook.content(
                source: source, book: book, chapter: firstChapter,
                nextChapterUrl: chapters[safe: 1]?.url
            )
            let preview = text.prefix(160).trimmingCharacters(in: .whitespacesAndNewlines)
            append(DebugStep(
                title: "正文",
                detail: "长度 \(text.count) 字\n\(preview)…",
                isError: text.isEmpty,
                duration: Date().timeIntervalSince(contentStart)
            ))
        } catch {
            append(DebugStep(
                title: "正文",
                detail: error.localizedDescription,
                isError: true,
                duration: Date().timeIntervalSince(contentStart)
            ))
        }
    }

    private func append(_ step: DebugStep) {
        steps.append(step)
    }
}

struct DebugStep: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let isError: Bool
    let duration: TimeInterval?

    var icon: String { isError ? "xmark.circle.fill" : "checkmark.circle.fill" }
    var color: Color { isError ? .red : .green }
}
