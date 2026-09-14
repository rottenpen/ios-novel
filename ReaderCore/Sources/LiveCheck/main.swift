import Foundation
import ReaderCore

/// 真实网络端到端验证工具。
///
/// 不放进单元测试，因为它依赖外部站点可用性，不具备可重复性。
/// 作为独立可执行体，用于人工确认「搜索 → 详情 → 目录 → 正文」在真实书源上走得通。
@main
struct LiveCheck {
    static func main() async {
        let args = CommandLine.arguments
        let keyword = args.count > 1 ? args[1] : "剑来"
        let limit = args.count > 2 ? (Int(args[2]) ?? 6) : 6

        guard let data = FileManager.default.contents(
            atPath: ProcessInfo.processInfo.environment["LIVECHECK_SOURCES"] ?? "/tmp/sy.json"
        ),
              let sources = try? JSONDecoder().decode([BookSource].self, from: data) else {
            print("无法读取书源文件")
            exit(1)
        }

        print("载入书源：\(sources.count) 个，关键词：\(keyword)\n")

        // 诊断模式：LiveCheck <关键词> <数量> diag <书源名关键字>
        // 打印真实请求参数与响应片段，用于区分「引擎解析错」与「站点返回空」
        if args.count > 4, args[3] == "diag" {
            let filter = args[4]
            guard let source = sources.first(where: { $0.bookSourceName.contains(filter) }) else {
                print("未找到书源：\(filter)")
                exit(1)
            }
            await diagnose(source: source, keyword: keyword)
            return
        }

        var okSearch = 0
        var okDetail = 0
        var okToc = 0
        var okContent = 0
        var checked = 0

        for source in sources.prefix(limit) {
            checked += 1
            let name = source.bookSourceName
            print("── \(name)")

            // 1) 搜索
            let books: [SearchBook]
            do {
                books = try await WebBook.search(source: source, key: keyword)
            } catch {
                print("   搜索失败：\(error.localizedDescription)\n")
                continue
            }
            guard let first = books.first else {
                print("   搜索无结果\n")
                continue
            }
            okSearch += 1
            print("   搜索 ✓ \(books.count) 条 → 《\(first.name)》\(first.author)")

            // 2) 详情
            var book = Book.from(searchBook: first)
            do {
                book = try await WebBook.bookInfo(source: source, book: book)
                okDetail += 1
                print("   详情 ✓ toc=\(book.tocUrl.prefix(60))")
            } catch {
                print("   详情失败：\(error.localizedDescription)\n")
                continue
            }

            // 3) 目录
            let chapters: [BookChapter]
            do {
                chapters = try await WebBook.chapterList(source: source, book: book)
                okToc += 1
                print("   目录 ✓ \(chapters.count) 章 → \(chapters.first?.title ?? "-")")
            } catch {
                print("   目录失败：\(error.localizedDescription)\n")
                continue
            }
            guard let firstChapter = chapters.first else { print("") ; continue }

            // 4) 正文
            do {
                let text = try await WebBook.content(
                    source: source, book: book, chapter: firstChapter,
                    nextChapterUrl: chapters.count > 1 ? chapters[1].url : nil
                )
                okContent += 1
                let preview = text
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .prefix(60)
                print("   正文 ✓ \(text.count) 字 → \(preview)…")
            } catch {
                print("   正文失败：\(error.localizedDescription)")
            }
            print("")
        }

        print("═══ 汇总（检查 \(checked) 个书源）")
        print("搜索成功：\(okSearch)/\(checked)")
        print("详情成功：\(okDetail)/\(checked)")
        print("目录成功：\(okToc)/\(checked)")
        print("正文成功：\(okContent)/\(checked)")
    }

    /// 单书源诊断：打印真实 URL / method / body / header 与响应体片段，
    /// 并单独跑一次 bookList 规则，定位失败发生在请求层还是解析层。
    static func diagnose(source: BookSource, keyword: String) async {
        print("═══ 诊断：\(source.bookSourceName)")
        print("bookSourceUrl: \(source.bookSourceUrl)")
        print("searchUrl 规则: \(source.searchUrl ?? "nil")")
        print("header 原文: \(source.header ?? "nil")")
        print("headerMap 解析后: \(source.headerMap())")
        print("")

        guard let searchUrl = source.searchUrl, !searchUrl.isEmpty else {
            print("无 searchUrl")
            return
        }

        let analyze: AnalyzeUrl
        do {
            analyze = try AnalyzeUrl(
                mUrl: searchUrl, key: keyword, page: 1,
                baseUrl: source.bookSourceUrl, source: source
            )
        } catch {
            print("AnalyzeUrl 构造失败：\(error)")
            return
        }

        print("── 实际请求")
        print("url    : \(analyze.url)")
        print("method : \(analyze.method)")
        print("body   : \(analyze.body ?? "nil")")
        print("headers: \(analyze.headerMap)")
        print("")

        do {
            let response = try await analyze.getStrResponse()
            let body = response.body ?? ""
            print("── 响应")
            print("status: \(response.statusCode)  finalUrl: \(response.url)")
            print("length: \(body.count)")
            print("命中关键词「\(keyword)」次数: \(body.components(separatedBy: keyword).count - 1)")
            let head = body.replacingOccurrences(of: "\n", with: " ").prefix(400)
            print("片段: \(head)")
            print("")

            // 单独验证 bookList 规则
            if let listRule = source.ruleSearch?.bookList, !listRule.isEmpty {
                let rule = AnalyzeRule(ruleData: RuleData(), source: source)
                rule.setContent(body, baseUrl: analyze.url)
                rule.setRedirectUrl(response.url)
                let elements = rule.getElements(listRule)
                print("── 解析")
                print("bookList 规则: \(listRule)")
                print("匹配到元素数: \(elements.count)")
            }
        } catch {
            print("请求失败：\(error)")
        }
    }
}
