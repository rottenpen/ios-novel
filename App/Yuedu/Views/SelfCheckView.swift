import SwiftUI
import ReaderCore

/// App 内真实链路自检页。
///
/// 走的是和用户完全相同的代码路径（SearchModel → WebBook → AnalyzeRule → HTTPClient），
/// 展示搜索、目录和正文的抓取结果，便于定位书源规则问题。
/// 通过启动参数 `-selfcheck <关键词>` 进入，不影响正常使用。
struct SelfCheckView: View {
    let keyword: String

    @EnvironmentObject private var sourceRepo: BookSourceRepository
    @State private var lines: [Line] = []
    @State private var finished = false

    struct Line: Identifiable {
        let id = UUID()
        let text: String
        let ok: Bool?
    }

    var body: some View {
        NavigationStack {
            List(lines) { line in
                HStack(alignment: .top, spacing: 8) {
                    if let ok = line.ok {
                        Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(ok ? .green : .red)
                    } else {
                        Image(systemName: "circle.dotted")
                            .foregroundStyle(.secondary)
                    }
                    Text(line.text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            .navigationTitle(finished ? "自检完成" : "自检中…")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await run() }
    }

    private func log(_ text: String, ok: Bool? = nil) {
        lines.append(Line(text: text, ok: ok))
    }

    private func run() async {
        log("关键词：\(keyword)")
        let sources = sourceRepo.enabledSources
        log("启用书源：\(sources.count) 个")
        guard let source = sources.first else {
            log("没有可用书源", ok: false)
            finished = true
            return
        }
        log("书源：\(source.bookSourceName)")

        // 1) 搜索
        let books: [SearchBook]
        do {
            books = try await WebBook.search(source: source, key: keyword)
        } catch {
            log("搜索失败：\(error.localizedDescription)", ok: false)
            finished = true
            return
        }
        guard let first = books.first else {
            log("搜索无结果", ok: false)
            finished = true
            return
        }
        log("搜索成功：\(books.count) 条，首条《\(first.name)》\(first.author)", ok: true)

        // 2) 详情
        var book = Book.from(searchBook: first)
        do {
            book = try await WebBook.bookInfo(source: source, book: book)
            log("详情成功：目录地址已获取", ok: true)
        } catch {
            log("详情失败：\(error.localizedDescription)", ok: false)
            finished = true
            return
        }

        // 3) 目录
        let chapters: [BookChapter]
        do {
            chapters = try await WebBook.chapterList(source: source, book: book)
            log("目录成功：\(chapters.count) 章，首章「\(chapters.first?.title ?? "-")」", ok: true)
        } catch {
            log("目录失败：\(error.localizedDescription)", ok: false)
            finished = true
            return
        }

        // 4) 正文
        guard let firstChapter = chapters.first else {
            finished = true
            return
        }
        do {
            let text = try await WebBook.content(
                source: source, book: book, chapter: firstChapter,
                nextChapterUrl: chapters.count > 1 ? chapters[1].url : nil
            )
            let preview = text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(50)
            log("正文成功：\(text.count) 字", ok: true)
            log("正文预览：\(preview)…")
        } catch {
            log("正文失败：\(error.localizedDescription)", ok: false)
        }

        // 5) 批量下载：走与用户完全相同的 DownloadManager 路径
        await checkDownload(source: source, book: book, chapters: chapters)
        finished = true
    }

    /// 下载自检：取前若干章跑一遍真实下载，校验落盘、跳过与进度统计。
    private func checkDownload(source: BookSource, book: Book, chapters: [BookChapter]) async {
        let sampleCount = min(5, chapters.count)
        guard sampleCount > 0 else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("selfcheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let shelf = BookshelfRepository(directory: directory)
        let manager = DownloadManager()
        let range = Array(0..<sampleCount)

        log("开始下载前 \(sampleCount) 章…")
        manager.start(book: book, chapters: chapters, source: source, shelf: shelf, range: range)
        // 等待下载结束，最多 60 秒
        for _ in 0..<600 {
            if !manager.isDownloading { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let progress = manager.progress
        let ok = progress.completed > 0 && progress.failed == 0
        log("下载结果：成功 \(progress.completed)，失败 \(progress.failed)", ok: ok)

        // 校验确实落盘可读
        var readable = 0
        var totalChars = 0
        for index in range {
            if let text = shelf.loadContent(bookUrl: book.bookUrl, chapterIndex: index),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                readable += 1
                totalChars += text.count
            }
        }
        log("落盘校验：\(readable)/\(sampleCount) 章可读，共 \(totalChars) 字",
            ok: readable == sampleCount)

        // 再次下载应全部跳过，验证断点续传不重复请求
        manager.start(book: book, chapters: chapters, source: source, shelf: shelf, range: range)
        for _ in 0..<100 {
            if !manager.isDownloading { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        log("重复下载跳过：\(manager.progress.skipped)/\(sampleCount) 章",
            ok: manager.progress.skipped == readable && readable > 0)
    }
}
