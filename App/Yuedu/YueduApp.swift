import SwiftUI
import ReaderCore

@main
struct YueduApp: App {
    // 仓库为全局单例，跨页面共享状态
    @StateObject private var sourceRepo = BookSourceRepository.shared
    @StateObject private var shelf = BookshelfRepository.shared

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
            .tint(DS.accent)
        }
    }
}

/// 根视图：三个主 Tab
struct RootView: View {
    @EnvironmentObject private var sourceRepo: BookSourceRepository
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            BookshelfView()
                .tabItem { Label("书架", systemImage: "books.vertical") }
                .tag(0)

            SearchView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(1)

            BookSourceView()
                .tabItem { Label("书源", systemImage: "square.stack.3d.up") }
                .tag(2)
                .badge(sourceRepo.sources.isEmpty ? "!" : nil)
        }
        // 搜索深链需要先切到搜索 Tab，否则 SearchView 收不到 onOpenURL
        .onOpenURL { url in
            if url.scheme == "yuedu", url.host == "search" {
                selection = 1
            }
        }
    }
}
