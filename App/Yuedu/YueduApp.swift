import SwiftUI
import ReaderCore

@main
struct YueduApp: App {
    // 仓库为全局单例，跨页面共享状态
    @StateObject private var sourceRepo = BookSourceRepository.shared
    @StateObject private var shelf = BookshelfRepository.shared
    @StateObject private var downloader = DownloadManager.shared

    /// 自检模式：通过启动参数 `-selfcheck <关键词>` 进入。
    private var selfCheckKeyword: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let idx = args.firstIndex(of: "-selfcheck"), idx + 1 < args.count else {
            return nil
        }
        return args[idx + 1]
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let keyword = selfCheckKeyword {
                    SelfCheckView(keyword: keyword)
                } else {
                    RootView()
                }
            }
            .environmentObject(sourceRepo)
            .environmentObject(shelf)
            .environmentObject(downloader)
            .tint(DS.accent)
        }
    }
}

/// 根视图：三个主 Tab
struct RootView: View {
    @EnvironmentObject private var sourceRepo: BookSourceRepository
    @EnvironmentObject private var shelf: BookshelfRepository
    @State private var selection = 0

    /// 冷启动自动续看，可在书架菜单关闭
    @AppStorage("shelf.autoResume") private var autoResume = true

    @State private var resume: ResumeSession?
    /// 仅冷启动尝试一次；从后台返回不重复弹出阅读器
    @State private var didAttemptResume = false
    /// 发现页点书后要在搜索页执行的关键词，切 Tab 后由 SearchView 消费
    @State private var pendingSearch: String?

    var body: some View {
        TabView(selection: $selection) {
            BookshelfView()
                .tabItem { Label("书架", systemImage: "books.vertical") }
                .tag(0)

            DiscoverView { keyword in
                // 发现页点书：切到搜索 Tab 并带上关键词
                pendingSearch = keyword
                selection = 2
            }
            .tabItem { Label("发现", systemImage: "sparkles") }
            .tag(1)

            SearchView(pendingKeyword: $pendingSearch)
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(2)

            BookSourceView()
                .tabItem { Label("书源", systemImage: "square.stack.3d.up") }
                .tag(3)
                .badge(sourceRepo.sources.isEmpty ? "!" : nil)
        }
        // 搜索深链需要先切到搜索 Tab，否则 SearchView 收不到 onOpenURL
        .onOpenURL { url in
            if url.scheme == "yuedu", url.host == "search" {
                // 深链优先于自动续看，避免抢占用户的明确意图
                didAttemptResume = true
                resume = nil
                selection = 2
            }
        }
        .task {
            guard !didAttemptResume else { return }
            didAttemptResume = true
            guard autoResume else { return }
            // 目录缓存缺失时 resumeCandidate() 返回 nil，此处留在书架
            guard let target = shelf.resumeCandidate() else { return }
            resume = ResumeSession(target: target)
        }
        .fullScreenCover(item: $resume) { session in
            ReaderHostView(
                book: session.target.book,
                chapters: session.target.chapters,
                startIndex: session.target.chapterIndex,
                startPosition: session.target.position
            ) { _, _ in }
        }
    }
}

/// 冷启动续看会话，用于 fullScreenCover(item:)
struct ResumeSession: Identifiable {
    let target: BookshelfRepository.ResumeTarget
    var id: String { target.book.bookUrl }
}
