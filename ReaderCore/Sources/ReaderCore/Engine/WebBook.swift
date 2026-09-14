// Swift 实现及修改：Yuedu 项目，2026-09-14。
// 来源与许可见仓库根目录 THIRD_PARTY_NOTICES.md（GPL-3.0）。
import Foundation
import SwiftSoup

/// 书源解析入口。
///
/// 所有方法都是 async 的，但规则解析（SwiftSoup / JavaScriptCore）本身是同步 CPU 密集操作，
/// 统一在 `RuleExecutor` 的后台线程上执行，既不阻塞主线程，也让书源 JS 里的同步网络请求
/// （`SyncHTTP`）不会与调用方线程产生死锁。
public enum WebBook {

    // MARK: - 搜索

    /// 搜索书籍，对应 `WebBook.searchBookAwait`
    public static func search(
        source: BookSource,
        key: String,
        page: Int = 1
    ) async throws -> [SearchBook] {
        guard let searchUrl = source.searchUrl, !searchUrl.isEmpty else {
            return []
        }
        let ruleData = RuleData()
        let analyzeUrl = try await RuleExecutor.run {
            try AnalyzeUrl(
                mUrl: searchUrl,
                key: key,
                page: page,
                baseUrl: source.bookSourceUrl,
                source: source,
                ruleData: ruleData
            )
        }
        let response = try await analyzeUrl.getStrResponse()
        return try await RuleExecutor.run {
            try analyzeBookList(
                source: source,
                ruleData: ruleData,
                analyzeUrl: analyzeUrl,
                baseUrl: response.url,
                body: response.body,
                isSearch: true
            )
        }
    }

    /// 发现页，对应 `WebBook.exploreBookAwait`
    public static func explore(
        source: BookSource,
        url: String,
        page: Int = 1
    ) async throws -> [SearchBook] {
        let ruleData = RuleData()
        let analyzeUrl = try await RuleExecutor.run {
            try AnalyzeUrl(
                mUrl: url,
                page: page,
                baseUrl: source.bookSourceUrl,
                source: source,
                ruleData: ruleData
            )
        }
        let response = try await analyzeUrl.getStrResponse()
        return try await RuleExecutor.run {
            try analyzeBookList(
                source: source,
                ruleData: ruleData,
                analyzeUrl: analyzeUrl,
                baseUrl: response.url,
                body: response.body,
                isSearch: false
            )
        }
    }

    /// 解析书籍列表，对应 `BookList.analyzeBookList`
    private static func analyzeBookList(
        source: BookSource,
        ruleData: RuleData,
        analyzeUrl: AnalyzeUrl,
        baseUrl: String,
        body: String?,
        isSearch: Bool
    ) throws -> [SearchBook] {
        guard let body, !body.isEmpty else {
            throw HTTPError.emptyBody(analyzeUrl.url)
        }

        var bookList: [SearchBook] = []
        let analyzeRule = AnalyzeRule(ruleData: ruleData, source: source)
        analyzeRule.setContent(body).setBaseUrl(baseUrl)
        analyzeRule.setRedirectUrl(baseUrl)

        // 搜索结果直接跳详情页的情况
        if isSearch, let pattern = source.bookUrlPattern, !pattern.isEmpty,
           baseUrl.range(of: pattern, options: .regularExpression) != nil {
            if let book = try infoItem(
                source: source, analyzeRule: analyzeRule,
                analyzeUrl: analyzeUrl, body: body, baseUrl: baseUrl
            ) {
                bookList.append(book)
            }
            return bookList
        }

        // 选择列表规则：发现页无 bookList 时回落到搜索规则
        let listRuleSource: BookListRuleProtocol
        if isSearch {
            listRuleSource = source.ruleSearch ?? SearchRule()
        } else if (source.ruleExplore?.bookList ?? "").isEmpty {
            listRuleSource = source.ruleSearch ?? SearchRule()
        } else {
            listRuleSource = source.ruleExplore ?? ExploreRule()
        }

        var ruleList = listRuleSource.bookList ?? ""
        var reverse = false
        if ruleList.hasPrefix("-") {
            reverse = true
            ruleList = String(ruleList.dropFirst())
        }
        if ruleList.hasPrefix("+") {
            ruleList = String(ruleList.dropFirst())
        }

        let collections = analyzeRule.getElements(ruleList)

        if collections.isEmpty, (source.bookUrlPattern ?? "").isEmpty {
            // 列表为空，按详情页解析（书源常见的单结果直跳）
            if let book = try infoItem(
                source: source, analyzeRule: analyzeRule,
                analyzeUrl: analyzeUrl, body: body, baseUrl: baseUrl
            ) {
                bookList.append(book)
            }
            return bookList
        }

        // 规则预拆分，循环内复用，避免每条书籍重复解析规则串
        let ruleName = analyzeRule.splitSourceRule(listRuleSource.name)
        let ruleBookUrl = analyzeRule.splitSourceRule(listRuleSource.bookUrl)
        let ruleAuthor = analyzeRule.splitSourceRule(listRuleSource.author)
        let ruleCoverUrl = analyzeRule.splitSourceRule(listRuleSource.coverUrl)
        let ruleIntro = analyzeRule.splitSourceRule(listRuleSource.intro)
        let ruleKind = analyzeRule.splitSourceRule(listRuleSource.kind)
        let ruleLastChapter = analyzeRule.splitSourceRule(listRuleSource.lastChapter)
        let ruleWordCount = analyzeRule.splitSourceRule(listRuleSource.wordCount)

        for item in collections {
            if let book = searchItem(
                source: source,
                analyzeRule: analyzeRule,
                item: item,
                baseUrl: baseUrl,
                ruleName: ruleName,
                ruleBookUrl: ruleBookUrl,
                ruleAuthor: ruleAuthor,
                ruleCoverUrl: ruleCoverUrl,
                ruleIntro: ruleIntro,
                ruleKind: ruleKind,
                ruleLastChapter: ruleLastChapter,
                ruleWordCount: ruleWordCount
            ) {
                bookList.append(book)
            }
        }

        // 去重（保序）。
        var seen = Set<String>()
        bookList = bookList.filter { seen.insert($0.id).inserted }
        if reverse { bookList.reverse() }
        return bookList
    }

    private static func searchItem(
        source: BookSource,
        analyzeRule: AnalyzeRule,
        item: Any,
        baseUrl: String,
        ruleName: [AnalyzeRule.SourceRule],
        ruleBookUrl: [AnalyzeRule.SourceRule],
        ruleAuthor: [AnalyzeRule.SourceRule],
        ruleCoverUrl: [AnalyzeRule.SourceRule],
        ruleIntro: [AnalyzeRule.SourceRule],
        ruleKind: [AnalyzeRule.SourceRule],
        ruleLastChapter: [AnalyzeRule.SourceRule],
        ruleWordCount: [AnalyzeRule.SourceRule]
    ) -> SearchBook? {
        var book = SearchBook()
        book.origin = source.bookSourceUrl
        book.originName = source.bookSourceName
        book.originOrder = source.customOrder ?? 0

        analyzeRule.setContent(item)
        book.name = TextFormatter.formatBookName(analyzeRule.getString(ruleName))
        // 书名为空视为无效条目
        guard !book.name.isEmpty else { return nil }

        book.author = TextFormatter.formatBookAuthor(analyzeRule.getString(ruleAuthor))
        book.kind = analyzeRule.getStringList(ruleKind)?.joined(separator: ",")
        book.wordCount = TextFormatter.wordCountFormat(analyzeRule.getString(ruleWordCount))
        book.latestChapterTitle = analyzeRule.getString(ruleLastChapter)
        book.intro = TextFormatter.format(analyzeRule.getString(ruleIntro))

        let cover = analyzeRule.getString(ruleCoverUrl)
        if !cover.isEmpty {
            book.coverUrl = NetworkUtils.absoluteURL(base: baseUrl, relative: cover)
        }

        book.bookUrl = analyzeRule.getString(ruleBookUrl, isUrl: true)
        if book.bookUrl.isEmpty { book.bookUrl = baseUrl }
        book.tocUrl = book.bookUrl
        return book
    }

    private static func infoItem(
        source: BookSource,
        analyzeRule: AnalyzeRule,
        analyzeUrl: AnalyzeUrl,
        body: String,
        baseUrl: String
    ) throws -> SearchBook? {
        var book = Book()
        book.bookUrl = NetworkUtils.absoluteURL(base: analyzeUrl.url, relative: analyzeUrl.ruleUrl)
        book.origin = source.bookSourceUrl
        book.originName = source.bookSourceName

        let bookData = BookRuleData(book: book)
        analyzeRule.ruleData = bookData
        try analyzeBookInfo(
            book: &book,
            body: body,
            analyzeRule: analyzeRule,
            source: source,
            baseUrl: baseUrl,
            redirectUrl: baseUrl,
            canReName: false,
            bookData: bookData
        )
        guard !book.name.isEmpty else { return nil }

        var searchBook = SearchBook()
        searchBook.bookUrl = book.bookUrl
        searchBook.tocUrl = book.tocUrl
        searchBook.origin = book.origin
        searchBook.originName = book.originName
        searchBook.name = book.name
        searchBook.author = book.author
        searchBook.kind = book.kind
        searchBook.coverUrl = book.coverUrl
        searchBook.intro = book.intro
        searchBook.wordCount = book.wordCount
        searchBook.latestChapterTitle = book.latestChapterTitle
        return searchBook
    }

    // MARK: - 详情

    /// 获取书籍详情，对应 `WebBook.getBookInfoAwait`
    public static func bookInfo(
        source: BookSource,
        book: Book,
        canReName: Bool = true
    ) async throws -> Book {
        // 用不可变副本参与并发闭包捕获，避免捕获可变变量
        let inputBook = book
        let bookData = BookRuleData(book: inputBook)
        let analyzeUrl = try await RuleExecutor.run {
            try AnalyzeUrl(
                mUrl: inputBook.bookUrl,
                baseUrl: source.bookSourceUrl,
                source: source,
                ruleData: bookData
            )
        }
        let response = try await analyzeUrl.getStrResponse()
        guard let body = response.body, !body.isEmpty else {
            throw HTTPError.emptyBody(inputBook.bookUrl)
        }

        var result = try await RuleExecutor.run { () -> Book in
            var mutable = inputBook
            let analyzeRule = AnalyzeRule(ruleData: bookData, source: source)
            analyzeRule.setContent(body).setBaseUrl(inputBook.bookUrl)
            analyzeRule.setRedirectUrl(response.url)
            try analyzeBookInfo(
                book: &mutable,
                body: body,
                analyzeRule: analyzeRule,
                source: source,
                baseUrl: inputBook.bookUrl,
                redirectUrl: response.url,
                canReName: canReName,
                bookData: bookData
            )
            return mutable
        }
        result.variable = bookData.variableJSON
        return result
    }

    /// 详情字段解析，对应 `BookInfo.analyzeBookInfo`
    private static func analyzeBookInfo(
        book: inout Book,
        body: String,
        analyzeRule: AnalyzeRule,
        source: BookSource,
        baseUrl: String,
        redirectUrl: String,
        canReName: Bool,
        bookData: BookRuleData
    ) throws {
        let infoRule = source.ruleBookInfo ?? BookInfoRule()

        // init 规则：把解析范围收窄到详情区块
        if let initRule = infoRule.initRule, !initRule.trimmingCharacters(in: .whitespaces).isEmpty {
            if let element = analyzeRule.getElement(initRule) {
                analyzeRule.setContent(element)
            }
        }

        let canRename = canReName && !(infoRule.canReName ?? "").isEmpty

        let name = TextFormatter.formatBookName(analyzeRule.getString(infoRule.name))
        if !name.isEmpty, canRename || book.name.isEmpty {
            book.name = name
        }
        let author = TextFormatter.formatBookAuthor(analyzeRule.getString(infoRule.author))
        if !author.isEmpty, canRename || book.author.isEmpty {
            book.author = author
        }
        if let kind = analyzeRule.getStringList(infoRule.kind)?.joined(separator: ","),
           !kind.isEmpty {
            book.kind = kind
        }
        let wordCount = TextFormatter.wordCountFormat(analyzeRule.getString(infoRule.wordCount))
        if !wordCount.isEmpty { book.wordCount = wordCount }

        let lastChapter = analyzeRule.getString(infoRule.lastChapter)
        if !lastChapter.isEmpty { book.latestChapterTitle = lastChapter }

        let intro = TextFormatter.format(analyzeRule.getString(infoRule.intro))
        if !intro.isEmpty { book.intro = intro }

        let cover = analyzeRule.getString(infoRule.coverUrl)
        if !cover.isEmpty {
            book.coverUrl = NetworkUtils.absoluteURL(base: redirectUrl, relative: cover)
        }

        book.tocUrl = analyzeRule.getString(infoRule.tocUrl, isUrl: true)
        if book.tocUrl.isEmpty { book.tocUrl = baseUrl }

        // 详情页与目录页同源时，正文解析可复用该 body（此处仅记录 URL，body 由上层缓存）
        book.variable = bookData.variableJSON
    }

    // MARK: - 目录

    /// 获取章节目录，对应 `WebBook.getChapterListAwait`
    public static func chapterList(
        source: BookSource,
        book: Book
    ) async throws -> [BookChapter] {
        let bookData = BookRuleData(book: book)
        let tocUrl = book.tocUrl.isEmpty ? book.bookUrl : book.tocUrl

        let analyzeUrl = try await RuleExecutor.run {
            try AnalyzeUrl(
                mUrl: tocUrl,
                baseUrl: book.bookUrl,
                source: source,
                ruleData: bookData
            )
        }
        let response = try await analyzeUrl.getStrResponse()
        guard let body = response.body, !body.isEmpty else {
            throw HTTPError.emptyBody(tocUrl)
        }

        let tocRule = source.ruleToc ?? TocRule()
        var rawListRule = tocRule.chapterList ?? ""
        var reverse = false
        if rawListRule.hasPrefix("-") {
            reverse = true
            rawListRule = String(rawListRule.dropFirst())
        }
        if rawListRule.hasPrefix("+") {
            rawListRule = String(rawListRule.dropFirst())
        }
        // 定型为常量，供并发闭包安全捕获
        let listRule = rawListRule

        var chapterList: [BookChapter] = []
        var nextUrlList: [String] = [response.url]

        let first = try await RuleExecutor.run {
            parseChapterPage(
                book: book, bookData: bookData, source: source,
                baseUrl: tocUrl, redirectUrl: response.url, body: body,
                tocRule: tocRule, listRule: listRule, getNextUrl: true
            )
        }
        chapterList.append(contentsOf: first.chapters)

        // 目录分页：单个 next 链式抓取，多个则并发抓取
        if first.nextUrls.count == 1 {
            var nextUrl = first.nextUrls[0]
            // 上限保护：避免书源规则错误导致无限翻页
            var guardCount = 0
            while !nextUrl.isEmpty, !nextUrlList.contains(nextUrl), guardCount < 500 {
                guardCount += 1
                nextUrlList.append(nextUrl)
                // 循环变量先定型，避免并发闭包捕获可变量
                let capturedNextUrl = nextUrl
                let nextAnalyze = try await RuleExecutor.run {
                    try AnalyzeUrl(
                        mUrl: capturedNextUrl, baseUrl: book.bookUrl,
                        source: source, ruleData: bookData
                    )
                }
                let nextResponse = try await nextAnalyze.getStrResponse()
                guard let nextBody = nextResponse.body, !nextBody.isEmpty else { break }
                let page = try await RuleExecutor.run {
                    parseChapterPage(
                        book: book, bookData: bookData, source: source,
                        baseUrl: capturedNextUrl, redirectUrl: nextResponse.url, body: nextBody,
                        tocRule: tocRule, listRule: listRule, getNextUrl: true
                    )
                }
                chapterList.append(contentsOf: page.chapters)
                nextUrl = page.nextUrls.first ?? ""
            }
        } else if first.nextUrls.count > 1 {
            // 并发抓取所有分页，限制并发度避免触发站点风控
            let pages = try await withThrowingTaskGroup(
                of: (Int, [BookChapter]).self
            ) { group -> [(Int, [BookChapter])] in
                var results: [(Int, [BookChapter])] = []
                var iterator = first.nextUrls.enumerated().makeIterator()
                let maxConcurrent = 4
                var running = 0

                func addNext() -> Bool {
                    guard let (index, urlStr) = iterator.next() else { return false }
                    group.addTask {
                        let analyze = try await RuleExecutor.run {
                            try AnalyzeUrl(
                                mUrl: urlStr, baseUrl: book.bookUrl,
                                source: source, ruleData: bookData
                            )
                        }
                        let res = try await analyze.getStrResponse()
                        guard let pageBody = res.body else { return (index, []) }
                        let page = try await RuleExecutor.run {
                            parseChapterPage(
                                book: book, bookData: bookData, source: source,
                                baseUrl: urlStr, redirectUrl: res.url, body: pageBody,
                                tocRule: tocRule, listRule: listRule, getNextUrl: false
                            )
                        }
                        return (index, page.chapters)
                    }
                    return true
                }

                while running < maxConcurrent, addNext() { running += 1 }
                while let result = try await group.next() {
                    results.append(result)
                    _ = addNext()
                }
                return results
            }
            // 按分页顺序拼接，保证章节顺序稳定
            for (_, chapters) in pages.sorted(by: { $0.0 < $1.0 }) {
                chapterList.append(contentsOf: chapters)
            }
        }

        guard !chapterList.isEmpty else {
            throw HTTPError.emptyBody("章节列表为空：\(tocUrl)")
        }

        // 去重（按 url + title 保序）
        var seen = Set<String>()
        chapterList = chapterList.filter { seen.insert("\($0.url)|\($0.title)").inserted }
        if reverse { chapterList.reverse() }

        // 重排 index 并执行 formatJs
        let formatJs = tocRule.formatJs
        for i in chapterList.indices {
            chapterList[i].index = i
            chapterList[i].bookUrl = book.bookUrl
            if let formatJs, !formatJs.trimmingCharacters(in: .whitespaces).isEmpty {
                let title = chapterList[i].title
                let value = JSEngine.shared.evaluate(
                    formatJs,
                    result: title,
                    source: source,
                    baseUrl: book.bookUrl,
                    variableStore: bookData.variableStore,
                    extraBindings: ["index": i + 1, "title": title]
                )
                if let formatted = AnalyzeUrl.stringify(value), !formatted.isEmpty {
                    chapterList[i].title = formatted
                }
            }
        }
        return chapterList
    }

    private struct ChapterPage {
        var chapters: [BookChapter]
        var nextUrls: [String]
    }

    /// 单页目录解析，对应 `BookChapterList.analyzeChapterList`
    private static func parseChapterPage(
        book: Book,
        bookData: BookRuleData,
        source: BookSource,
        baseUrl: String,
        redirectUrl: String,
        body: String,
        tocRule: TocRule,
        listRule: String,
        getNextUrl: Bool
    ) -> ChapterPage {
        let analyzeRule = AnalyzeRule(ruleData: bookData, source: source)
        analyzeRule.setContent(body).setBaseUrl(baseUrl)
        analyzeRule.setRedirectUrl(redirectUrl)

        let elements = analyzeRule.getElements(listRule)

        var nextUrls: [String] = []
        if getNextUrl, let nextRule = tocRule.nextTocUrl, !nextRule.isEmpty {
            if let list = analyzeRule.getStringList(nextRule, isUrl: true) {
                for item in list where item != redirectUrl {
                    nextUrls.append(item)
                }
            }
        }

        var chapters: [BookChapter] = []
        guard !elements.isEmpty else { return ChapterPage(chapters: chapters, nextUrls: nextUrls) }

        let nameRule = analyzeRule.splitSourceRule(tocRule.chapterName)
        let urlRule = analyzeRule.splitSourceRule(tocRule.chapterUrl)
        let vipRule = analyzeRule.splitSourceRule(tocRule.isVip)
        let payRule = analyzeRule.splitSourceRule(tocRule.isPay)
        let upTimeRule = analyzeRule.splitSourceRule(tocRule.updateTime)
        let isVolumeRule = analyzeRule.splitSourceRule(tocRule.isVolume)

        for (index, item) in elements.enumerated() {
            analyzeRule.setContent(item)
            var chapter = BookChapter()
            chapter.bookUrl = book.bookUrl
            chapter.baseUrl = redirectUrl
            analyzeRule.chapter = chapter

            chapter.title = analyzeRule.getString(nameRule)
            chapter.url = analyzeRule.getString(urlRule, isUrl: true)
            chapter.tag = analyzeRule.getString(upTimeRule)
            chapter.isVolume = TextFormatter.isTrue(analyzeRule.getString(isVolumeRule))

            if chapter.url.isEmpty {
                // 卷标题无链接时用标题占位，普通章节回落到 baseUrl
                chapter.url = chapter.isVolume ? "\(chapter.title)\(index)" : baseUrl
            }
            guard !chapter.title.isEmpty else { continue }

            chapter.isVip = TextFormatter.isTrue(analyzeRule.getString(vipRule))
            chapter.isPay = TextFormatter.isTrue(analyzeRule.getString(payRule))
            chapters.append(chapter)
        }
        return ChapterPage(chapters: chapters, nextUrls: nextUrls)
    }

    // MARK: - 正文

    /// 获取章节正文，对应 `WebBook.getContentAwait`
    public static func content(
        source: BookSource,
        book: Book,
        chapter: BookChapter,
        nextChapterUrl: String? = nil
    ) async throws -> String {
        // 卷标题无正文
        if chapter.isVolume, chapter.url.hasPrefix(chapter.title) {
            return chapter.title
        }

        let bookData = BookRuleData(book: book)
        let analyzeUrl = try await RuleExecutor.run {
            try AnalyzeUrl(
                mUrl: chapter.url,
                baseUrl: book.bookUrl,
                source: source,
                ruleData: bookData,
                chapter: chapter
            )
        }
        let response = try await analyzeUrl.getStrResponse()
        guard let body = response.body, !body.isEmpty else {
            throw HTTPError.emptyBody(chapter.url)
        }

        let contentRule = source.ruleContent ?? ContentRule()
        var contentList: [String] = []
        var nextUrlList: [String] = [response.url]

        let first = try await RuleExecutor.run {
            parseContentPage(
                book: book, bookData: bookData, source: source, chapter: chapter,
                baseUrl: chapter.url, redirectUrl: response.url, body: body,
                contentRule: contentRule, nextChapterUrl: nextChapterUrl,
                getNextPageUrl: true
            )
        }
        contentList.append(first.content)

        // 正文分页
        if first.nextUrls.count == 1 {
            var nextUrl = first.nextUrls[0]
            var guardCount = 0
            while !nextUrl.isEmpty, !nextUrlList.contains(nextUrl), guardCount < 200 {
                // 下一页等于下一章时终止，避免把下一章内容并进本章
                if let nextChapterUrl, !nextChapterUrl.isEmpty,
                   NetworkUtils.absoluteURL(base: response.url, relative: nextUrl)
                    == NetworkUtils.absoluteURL(base: response.url, relative: nextChapterUrl) {
                    break
                }
                guardCount += 1
                nextUrlList.append(nextUrl)

                // 循环变量先定型，避免并发闭包捕获可变量
                let capturedNextUrl = nextUrl
                let nextAnalyze = try await RuleExecutor.run {
                    try AnalyzeUrl(
                        mUrl: capturedNextUrl, baseUrl: book.bookUrl,
                        source: source, ruleData: bookData, chapter: chapter
                    )
                }
                let nextResponse = try await nextAnalyze.getStrResponse()
                guard let nextBody = nextResponse.body, !nextBody.isEmpty else { break }
                let page = try await RuleExecutor.run {
                    parseContentPage(
                        book: book, bookData: bookData, source: source, chapter: chapter,
                        baseUrl: capturedNextUrl, redirectUrl: nextResponse.url, body: nextBody,
                        contentRule: contentRule, nextChapterUrl: nextChapterUrl,
                        getNextPageUrl: true
                    )
                }
                contentList.append(page.content)
                nextUrl = page.nextUrls.first ?? ""
            }
        } else if first.nextUrls.count > 1 {
            let pages = try await withThrowingTaskGroup(
                of: (Int, String).self
            ) { group -> [(Int, String)] in
                for (index, urlStr) in first.nextUrls.enumerated() {
                    group.addTask {
                        let analyze = try await RuleExecutor.run {
                            try AnalyzeUrl(
                                mUrl: urlStr, baseUrl: book.bookUrl,
                                source: source, ruleData: bookData, chapter: chapter
                            )
                        }
                        let res = try await analyze.getStrResponse()
                        guard let pageBody = res.body else { return (index, "") }
                        let page = try await RuleExecutor.run {
                            parseContentPage(
                                book: book, bookData: bookData, source: source, chapter: chapter,
                                baseUrl: urlStr, redirectUrl: res.url, body: pageBody,
                                contentRule: contentRule, nextChapterUrl: nextChapterUrl,
                                getNextPageUrl: false
                            )
                        }
                        return (index, page.content)
                    }
                }
                var results: [(Int, String)] = []
                while let result = try await group.next() { results.append(result) }
                return results
            }
            for (_, text) in pages.sorted(by: { $0.0 < $1.0 }) {
                contentList.append(text)
            }
        }

        var contentStr = contentList.joined(separator: "\n")

        // 全文替换规则
        if let replaceRegex = contentRule.replaceRegex, !replaceRegex.isEmpty {
            // 定型为常量后再进入并发闭包
            let joined = contentStr
            contentStr = try await RuleExecutor.run {
                let analyzeRule = AnalyzeRule(ruleData: bookData, source: source)
                analyzeRule.setContent(body, baseUrl: chapter.url)
                analyzeRule.setRedirectUrl(response.url)
                analyzeRule.chapter = chapter
                let trimmed = joined
                    .components(separatedBy: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: "\n")
                let replaced = analyzeRule.getString(replaceRegex, mContent: trimmed)
                // 段首缩进
                return replaced
                    .components(separatedBy: "\n")
                    .map { "　　\($0)" }
                    .joined(separator: "\n")
            }
        }

        guard chapter.isVolume || !contentStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw HTTPError.emptyBody("正文内容为空：\(chapter.url)")
        }
        return contentStr
    }

    private struct ContentPage {
        var content: String
        var nextUrls: [String]
    }

    /// 单页正文解析，对应 `BookContent.analyzeContent`
    private static func parseContentPage(
        book: Book,
        bookData: BookRuleData,
        source: BookSource,
        chapter: BookChapter,
        baseUrl: String,
        redirectUrl: String,
        body: String,
        contentRule: ContentRule,
        nextChapterUrl: String?,
        getNextPageUrl: Bool
    ) -> ContentPage {
        let analyzeRule = AnalyzeRule(ruleData: bookData, source: source)
        analyzeRule.setContent(body, baseUrl: baseUrl)
        analyzeRule.setRedirectUrl(redirectUrl)
        analyzeRule.chapter = chapter
        analyzeRule.nextChapterUrl = nextChapterUrl

        // 正文不做 HTML 反转义，保留 <img>，之后统一处理
        var content = analyzeRule.getString(contentRule.content, unescape: false)
        content = TextFormatter.formatKeepImg(content, redirectUrl: redirectUrl)
        if content.contains("&") {
            content = TextFormatter.unescapeHTML(content)
        }

        var nextUrls: [String] = []
        if getNextPageUrl, let nextRule = contentRule.nextContentUrl, !nextRule.isEmpty {
            if let list = analyzeRule.getStringList(nextRule, isUrl: true) {
                nextUrls.append(contentsOf: list)
            }
        }
        return ContentPage(content: content, nextUrls: nextUrls)
    }
}

/// 规则解析执行器。
///
/// 规则解析是同步 CPU 密集操作，且书源 JS 内部会用信号量做同步网络请求。
/// 放到专用串行队列而非 Swift Concurrency 的协作线程池上执行，避免：
/// 1. 阻塞协作线程池导致其他 async 任务饥饿（Swift 并发的已知陷阱）
/// 2. 主线程卡顿
enum RuleExecutor {
    /// 用并发队列 + 有限并发，兼顾吞吐与线程占用
    private static let queue = DispatchQueue(
        label: "com.yuedu.rule-executor",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// 在后台线程执行同步解析逻辑
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
