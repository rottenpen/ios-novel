// Swift 实现及修改：Yuedu 项目，2026-09-14。
// 来源与许可见仓库根目录 THIRD_PARTY_NOTICES.md（GPL-3.0）。
import Foundation

/// 搜索结果条目。
public struct SearchBook: Sendable, Identifiable, Hashable {
    public var bookUrl: String = ""
    public var origin: String = ""
    public var originName: String = ""
    public var name: String = ""
    public var author: String = ""
    public var kind: String?
    public var coverUrl: String?
    public var intro: String?
    public var wordCount: String?
    public var latestChapterTitle: String?
    public var tocUrl: String = ""
    public var originOrder: Int = 0

    public init() {}

    public var id: String { "\(origin)|\(bookUrl)" }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bookUrl)
        hasher.combine(origin)
    }

    public static func == (lhs: SearchBook, rhs: SearchBook) -> Bool {
        lhs.bookUrl == rhs.bookUrl && lhs.origin == rhs.origin
    }
}

/// 书籍。
public struct Book: Sendable, Identifiable, Hashable, Codable {
    public var bookUrl: String = ""
    public var tocUrl: String = ""
    public var origin: String = ""
    public var originName: String = ""
    public var name: String = ""
    public var author: String = ""
    public var kind: String?
    public var customTag: String?
    public var coverUrl: String?
    public var customCoverUrl: String?
    public var intro: String?
    public var customIntro: String?
    public var wordCount: String?
    public var latestChapterTitle: String?
    public var totalChapterNum: Int = 0
    public var durChapterIndex: Int = 0
    public var durChapterPos: Int = 0
    public var durChapterTitle: String?
    public var durChapterTime: Double = 0
    public var lastCheckTime: Double = 0
    public var canUpdate: Bool = true
    public var order: Int = 0
    /// 书源自定义变量存储。
    public var variable: String?

    public init() {}

    public var id: String { bookUrl }

    public var displayCover: String? {
        customCoverUrl?.isEmpty == false ? customCoverUrl : coverUrl
    }

    public var displayIntro: String? {
        customIntro?.isEmpty == false ? customIntro : intro
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(bookUrl)
    }

    public static func == (lhs: Book, rhs: Book) -> Bool {
        lhs.bookUrl == rhs.bookUrl
    }

    public static func from(searchBook: SearchBook) -> Book {
        var book = Book()
        book.bookUrl = searchBook.bookUrl
        book.tocUrl = searchBook.tocUrl
        book.origin = searchBook.origin
        book.originName = searchBook.originName
        book.name = searchBook.name
        book.author = searchBook.author
        book.kind = searchBook.kind
        book.coverUrl = searchBook.coverUrl
        book.intro = searchBook.intro
        book.wordCount = searchBook.wordCount
        book.latestChapterTitle = searchBook.latestChapterTitle
        return book
    }
}

/// 章节。
public struct BookChapter: Sendable, Identifiable, Hashable, Codable {
    public var url: String = ""
    public var title: String = ""
    public var baseUrl: String = ""
    public var bookUrl: String = ""
    public var index: Int = 0
    public var isVolume: Bool = false
    public var isVip: Bool = false
    public var isPay: Bool = false
    public var resourceUrl: String?
    public var tag: String?
    public var start: Int?
    public var end: Int?
    public var variable: String?

    public init() {}

    public var id: String { "\(bookUrl)|\(index)|\(url)" }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(index)
    }

    public static func == (lhs: BookChapter, rhs: BookChapter) -> Bool {
        lhs.url == rhs.url && lhs.index == rhs.index
    }
}

/// 发现页分类。
public struct ExploreKind: Sendable, Identifiable, Hashable {
    public var title: String
    public var url: String?
    public var style: String?

    public init(title: String, url: String? = nil, style: String? = nil) {
        self.title = title
        self.url = url
        self.style = style
    }

    public var id: String { "\(title)|\(url ?? "")" }
}
